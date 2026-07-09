import QtQuick
import QtQuick.Controls
import "."

Rectangle {
    id: idx
    signal searchDone()
    function focusSearch() { sInput.forceActiveFocus() }
    readonly property bool searchFocus: sInput.activeFocus
    color: Theme.bg
    property bool active: true

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
        function onCurrentFolderIdChanged() { list.currentIndex = 0 }
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
            anchors.right: parent.right; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 230; height: 30; radius: 8
            color: Theme.surface
            border.width: 1
            border.color: sInput.activeFocus ? Theme.fg_muted : Theme.hairline
            TextField {
                id: sInput
                anchors.fill: parent; anchors.leftMargin: 8
                color: Theme.fg; background: null
                placeholderText: "search…  (/)"
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

        delegate: Rectangle {
            id: row
            required property int index
            required property string tid
            required property string subject
            required property string snippet
            required property string who
            required property string dateStr
            required property bool unread
            required property bool starred
            width: list.width; height: 38
            readonly property bool cursor: index === list.currentIndex
            color: cursor && idx.active ? Theme.surface2 : "transparent"

            // vim hybrid gutter: distance-from-cursor, orange bar on cursor row
            Item {
                id: gutter
                width: 22; height: parent.height
                anchors.left: parent.left; anchors.leftMargin: 4
                visible: idx.active
                Text {
                    renderType: Text.NativeRendering
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
                    width: 3; height: 16; radius: 2; color: Theme.cursor
                }
            }

            // unread dot
            Rectangle {
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 32 : 12
                anchors.verticalCenter: parent.verticalCenter
                width: 7; height: 7; radius: 4
                color: Theme.cursor
                visible: row.unread
            }

            Text {
                id: star
                renderType: Text.NativeRendering
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 46 : 26
                anchors.verticalCenter: parent.verticalCenter
                text: row.starred ? "" : ""
                color: Theme.yellow
                font.family: Theme.fontFamily; font.pixelSize: 12
                width: 16
            }

            Text {
                id: whoText
                renderType: Text.NativeRendering
                anchors.left: star.right; anchors.leftMargin: 4
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
                color: row.unread ? Theme.fg : Theme.fg_secondary
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.weight: row.unread ? 600 : 400
                elide: Text.ElideRight
            }

            Text {
                id: when
                renderType: Text.NativeRendering
                anchors.right: parent.right; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: row.dateStr
                color: row.unread ? Theme.fg : Theme.fg_muted
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
