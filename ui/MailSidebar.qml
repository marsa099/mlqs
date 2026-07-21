import QtQuick
import "."
import QsLib

// Folder sidebar in the chat clients' visual language: inverted ink-pill
// cursor, faint tint on the open folder, loud/quiet unread hierarchy.
Rectangle {
    id: bar
    signal composeRequested()
    // sits directly on the window canvas — no own surface, no divider
    color: "transparent"
    property bool active: false
    property int sel: 0
    opacity: active ? 1.0 : 0.8
    Behavior on opacity { NumberAnimation { duration: 120 } }

    // gutter shortcut chip: these keys jump globally from normal mode
    readonly property var roleKey: ({ inbox: "I", starred: "gI", sent: "gs", drafts: "gd", spam: "gS", trash: "gT" })
    component JumpCap: KeyCap {
        property string cap: ""
        property bool onInk: false
        visible: cap !== ""
        small: true; ghost: true
        text: cap
        // fixed box: single-char caps (I, T, C) otherwise shrink below the
        // two-char ones and the gutter rhythm falls apart
        width: 21
        border.color: onInk ? Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.35) : Theme.hairline
        textColor: onInk ? Theme.bg : Theme.fg_muted
    }

    // labels are clutter by default; the section header toggles
    property bool labelsCollapsed: true
    readonly property var roleIcon: ({
        inbox: "inbox-arrow-down", starred: "flag-7", sent: "paper-plane-2",
        drafts: "pen-3", spam: "triangle-warning", trash: "trash", label: "tag"
    })
    readonly property var visibleFolders: labelsCollapsed
        ? Backend.folders.filter(f => f.section !== "labels") : Backend.folders

    // pinned virtual rows above the folders: Threads (-2), Calendar (-1)
    function move(d) {
        if (visibleFolders.length === 0) return
        sel = Math.max(-2, Math.min(visibleFolders.length - 1, sel + d))
        if (sel >= 0) list.positionViewAtIndex(sel, ListView.Contain)
    }
    function choose() {
        if (sel === -2) { Backend.selectThreads(); return }
        if (sel === -1) { Backend.selectCalendar(); return }
        const f = visibleFolders[sel]
        if (f) Backend.selectFolder(f.id, f.name)
    }
    Connections {
        target: Backend
        function onCurrentFolderIdChanged() {
            if (Backend.currentFolderId === "__threads") { bar.sel = -2; return }
            if (Backend.currentFolderId === "__calendar") { bar.sel = -1; return }
            const i = bar.visibleFolders.findIndex(f => f.id === Backend.currentFolderId)
            if (i >= 0) bar.sel = i
        }
    }

    // account tabs: same 52px band + pill tabs as the chat workspace header
    Item {
        id: acctHeader
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: 52
        // new-message button (reference: circular quill, header right)
        Rectangle {
            anchors.right: parent.right; anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 32; height: 32; radius: 16
            color: Theme.mode === "light" ? Theme.bg : Theme.surface2
            border.width: 1; border.color: Theme.hairline
            Icon {
                anchors.centerIn: parent; width: 16; height: 16
                name: "pen-3"; color: Theme.fg
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: bar.composeRequested() }
        }
        Row {
            anchors.left: parent.left; anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Repeater {
                model: Backend.workspaces
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool activeTab: modelData.id === Backend.currentAccount
                    readonly property int tabUnread: Backend.accountUnread[modelData.id] || 0
                    height: 26; radius: 13
                    width: Math.min(tabLbl.implicitWidth + 20, 110)
                    // snap, don't animate — a fade reads as a blink on switch
                    color: activeTab ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10)
                         : tabHov.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: activeTab ? Theme.hairline : "transparent"
                    HoverHandler { id: tabHov }
                    Text {
                        id: tabLbl
                        anchors.centerIn: parent
                        text: modelData.name
                        color: activeTab ? Theme.fg : Theme.dimmedFg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 12; font.weight: activeTab ? 500 : 400
                        elide: Text.ElideRight; width: Math.min(implicitWidth, 90)
                        horizontalAlignment: Text.AlignHCenter
                    }
                    // inbox count on inactive accounts, riding the tab corner
                    Rectangle {
                        visible: !activeTab && tabUnread > 0
                        anchors.right: parent.right; anchors.rightMargin: -5
                        anchors.top: parent.top; anchors.topMargin: -5
                        height: 15; width: Math.max(15, tabBadge.implicitWidth + 8)
                        radius: 8; color: Theme.cursor
                        Text {
                            id: tabBadge
                            anchors.centerIn: parent
                            text: tabUnread > 99 ? "99+" : tabUnread
                            color: Theme.ink
                            font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: 600
                            font.features: ({ "tnum": 1 })
                        }
                    }
                    TapHandler { onTapped: Backend.selectAccount(modelData.id) }
                }
            }
        }
    }

    // pinned Threads: conversations you participate in, across all folders
    Item {
        id: threadsRow
        anchors { top: acctHeader.bottom; topMargin: 10; left: parent.left; right: parent.right }
        height: 42
        readonly property bool isOpen: Backend.currentFolderId === "__threads"
        readonly property bool primary: bar.active && bar.sel === -2
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 6; anchors.rightMargin: 6
            radius: height / 2
            color: threadsRow.primary ? Theme.fg
                 : (threadsRow.isOpen && !bar.active ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                           : hovT.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent")
        }
        HoverHandler { id: hovT }
        Rectangle {
            visible: bar.active && bar.sel === -2
            anchors.left: parent.left; anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            width: 3; height: 16; radius: 2; color: Theme.cursor
        }
        JumpCap {
            cap: "T"; onInk: threadsRow.primary
            visible: !(bar.active && bar.sel === -2)
            anchors.left: parent.left; anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
        }
        Row {
            anchors.fill: parent
            anchors.leftMargin: 36
            spacing: 13
            Icon {
                width: 18; height: 18
                anchors.verticalCenter: parent.verticalCenter
                name: "msgs"
                color: threadsRow.primary ? Theme.bg
                     : (threadsRow.isOpen || bar.sel === -2) ? Theme.fg : Theme.fg_muted
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Threads"
                color: threadsRow.primary ? Theme.bg
                     : (threadsRow.isOpen || bar.sel === -2) ? Theme.fg : Theme.dimmedFg
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 14
            }
        }
        TapHandler {
            onTapped: { bar.sel = -2; Backend.selectThreads() }
        }
    }

    // pinned Calendar: merged agenda across accounts
    Item {
        id: calRow
        anchors { top: threadsRow.bottom; left: parent.left; right: parent.right }
        height: 42
        readonly property bool isOpen: Backend.currentFolderId === "__calendar"
        readonly property bool primary: bar.active && bar.sel === -1
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 6; anchors.rightMargin: 6
            radius: height / 2
            color: calRow.primary ? Theme.fg
                 : (calRow.isOpen && !bar.active ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                           : hovC.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent")
        }
        HoverHandler { id: hovC }
        Rectangle {
            visible: bar.active && bar.sel === -1
            anchors.left: parent.left; anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            width: 3; height: 16; radius: 2; color: Theme.cursor
        }
        JumpCap {
            cap: "C"; onInk: calRow.primary
            visible: !(bar.active && bar.sel === -1)
            anchors.left: parent.left; anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
        }
        Row {
            anchors.fill: parent
            anchors.leftMargin: 36
            spacing: 13
            Icon {
                width: 18; height: 18
                anchors.verticalCenter: parent.verticalCenter
                name: "calendar-days"
                color: calRow.primary ? Theme.bg
                     : (calRow.isOpen || bar.sel === -1) ? Theme.fg : Theme.fg_muted
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Calendar"
                color: calRow.primary ? Theme.bg
                     : (calRow.isOpen || bar.sel === -1) ? Theme.fg : Theme.dimmedFg
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 14
            }
        }
        TapHandler {
            onTapped: { bar.sel = -1; Backend.selectCalendar() }
        }
    }

    ListView {
        id: list
        anchors { top: calRow.bottom; topMargin: 2; left: parent.left; right: parent.right; bottom: parent.bottom }
        model: bar.visibleFolders
        clip: true
        spacing: 2
        boundsBehavior: Flickable.StopAtBounds

        section.property: "section"
        section.delegate: Item {
            required property string section
            width: list.width
            height: 34
            Text {
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                text: section.toUpperCase() + (section === "labels" ? "  ▾" : "")
                color: Theme.fg_muted; font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 11; font.weight: 500; font.letterSpacing: 1.2
            }
            TapHandler {
                enabled: section === "labels"
                onTapped: bar.labelsCollapsed = true
            }
        }

        // collapsed stub: click to expand; shows the labels' pooled unread
        footer: Item {
            visible: bar.labelsCollapsed
            width: list.width
            height: bar.labelsCollapsed ? 34 : 0
            Text {
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                text: {
                    let n = 0
                    for (const f of Backend.folders) if (f.section === "labels") n += f.unread || 0
                    return "LABELS  ▸" + (n > 0 ? "  · " + n : "")
                }
                color: Theme.fg_muted; font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 11; font.weight: 500; font.letterSpacing: 1.2
            }
            TapHandler { onTapped: bar.labelsCollapsed = false }
        }

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: list.width; height: 42
            readonly property bool cursor: index === bar.sel
            readonly property bool isOpen: modelData.id === Backend.currentFolderId
            readonly property bool primary: bar.active && cursor
            // inbox unread is the "loud" count (filled accent pill, like
            // mentions/DMs in chat); other folders stay quiet muted numbers
            readonly property bool loudUnread: modelData.unread > 0 && modelData.role === "inbox"
            // junk-folder unreads don't deserve emphasis — spam/trash stay muted
            readonly property bool emphasize: modelData.unread > 0
                && modelData.role !== "spam" && modelData.role !== "trash"

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 6; anchors.rightMargin: 6
                radius: height / 2
                color: row.primary ? Theme.fg
                     : (row.isOpen && !bar.active ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                               : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent")
            }
            HoverHandler { id: hov }

            // gutter shows the folder's global jump key (i inbox, s sent)
            JumpCap {
                cap: bar.roleKey[modelData.role] || ""
                onInk: row.primary
                visible: !(bar.active && row.cursor)
                anchors.left: parent.left; anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                visible: bar.active && row.cursor
                anchors.left: parent.left; anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 16; radius: 2; color: Theme.cursor
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 36
                anchors.rightMargin: 8 + (modelData.unread > 0 ? 38 : 0)
                spacing: 13
                Icon {
                    id: glyph
                    width: 18; height: 18
                    anchors.verticalCenter: parent.verticalCenter
                    name: bar.roleIcon[modelData.role] || "tag"
                    color: row.primary ? Theme.bg
                         : (row.emphasize || row.isOpen || row.cursor) ? Theme.fg : Theme.fg_muted
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - glyph.width - parent.spacing
                    text: modelData.role === "label" ? modelData.name
                        : (modelData.name.charAt(0) + modelData.name.slice(1).toLowerCase())
                    elide: Text.ElideRight
                    color: row.primary ? Theme.bg
                         : (row.emphasize || row.isOpen || row.cursor) ? Theme.fg : Theme.dimmedFg
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 14
                    font.weight: row.emphasize ? 500 : Theme.fontWeight
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
                    id: ub; anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    text: modelData.unread > 9999 ? "9999+" : modelData.unread
                    color: Theme.ink
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12; font.weight: 500; font.features: ({ "tnum": 1 })
                }
            }
            // quiet: bare muted count
            Text {
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
