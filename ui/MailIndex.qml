import QtQuick
import "."

Rectangle {
    id: idx
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
    function current() { return Backend.convs[list.currentIndex] }
    function open() { Backend.openConv(current()) }

    // header: folder name + count
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 40; color: Theme.bg
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
            required property var modelData
            required property int index
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
                visible: modelData.unread
            }

            Text {
                id: star
                renderType: Text.NativeRendering
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 46 : 26
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.starred ? "" : ""
                color: Theme.yellow
                font.family: Theme.fontFamily; font.pixelSize: 12
                width: 16
            }

            Text {
                id: who
                renderType: Text.NativeRendering
                anchors.left: star.right; anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                width: 210
                text: Backend.senderLine(modelData) + (modelData.msgCount > 1 ? " (" + modelData.msgCount + ")" : "")
                color: modelData.unread ? Theme.fg : Theme.fg_secondary
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.weight: modelData.unread ? 600 : 400
                elide: Text.ElideRight
            }

            Text {
                renderType: Text.NativeRendering
                anchors.left: who.right; anchors.leftMargin: 14
                anchors.right: when.left; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.StyledText
                text: {
                    const subj = (modelData.subject || "(no subject)")
                        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    const snip = (modelData.snippet || "")
                        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    return subj + (snip ? "  <font color='" + Theme.fg_muted + "'>— " + snip + "</font>" : "")
                }
                color: modelData.unread ? Theme.fg : Theme.fg_secondary
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.weight: modelData.unread ? 600 : 400
                elide: Text.ElideRight
            }

            Text {
                id: when
                renderType: Text.NativeRendering
                anchors.right: parent.right; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: Backend.fmtDate(modelData.date)
                color: modelData.unread ? Theme.fg : Theme.fg_muted
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
