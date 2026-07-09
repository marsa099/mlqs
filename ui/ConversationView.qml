import QtQuick
import "."

Rectangle {
    id: cv
    color: Theme.bg

    function move(d) {
        if (list.count === 0) return
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
        list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
    }
    function clampY(y) {
        return Math.max(list.originY, Math.min(list.originY + list.contentHeight - list.height, y))
    }
    function scrollLine(d) { list.contentY = clampY(list.contentY + d * 90) }
    function scroll(d) { list.contentY = clampY(list.contentY + d * list.height / 2) }
    function toTop() { list.contentY = list.originY; list.currentIndex = 0 }
    function toEnd() { list.contentY = clampY(list.originY + list.contentHeight); list.currentIndex = list.count - 1 }
    // newest message focused, scrolled to its TOP (not its end — a long
    // newsletter must open at the start, not the footer)
    function focusNewest() {
        list.currentIndex = list.count - 1
        list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
    }
    function openCurrentHtml() {
        const m = Backend.messages[list.currentIndex]
        if (m && m.hasHtml) Backend.openHtml(m.id)
        else Backend.toast("no html body")
    }
    Connections {
        target: Backend
        function onMessagesChanged() {
            if (Backend.messages.length > 0) Qt.callLater(cv.focusNewest)
        }
    }

    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 40; color: Theme.bg
        Text {
            renderType: Text.NativeRendering
            anchors.left: parent.left; anchors.leftMargin: 14
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: Backend.openConvSubject
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 14; font.weight: 600
            elide: Text.ElideRight
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
    }

    ListView {
        id: list
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 0 }
        model: Backend.messages
        clip: true
        spacing: 10
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 60

        property real scrollGain: 5.0
        WheelHandler {
            acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
            onWheel: e => {
                const px = (e.pixelDelta.y !== 0) ? e.pixelDelta.y : e.angleDelta.y / 8
                list.contentY -= px * list.scrollGain
                list.returnToBounds()
                e.accepted = true
            }
        }

        delegate: Rectangle {
            required property var modelData
            required property int index
            width: list.width
            height: content.height + 24
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                radius: Theme.radius
                color: index === list.currentIndex ? Theme.surface1 : "transparent"
                border.color: index === list.currentIndex ? Theme.hairline : "transparent"
                border.width: 1
            }

            Column {
                id: content
                anchors.top: parent.top; anchors.topMargin: 12
                anchors.left: parent.left; anchors.leftMargin: 24
                // readable column: don't let body lines run the full window width
                width: Math.min(parent.width - 48, 820)
                spacing: 8

                Row {
                    spacing: 10
                    Text {
                        renderType: Text.NativeRendering
                        text: modelData.from ? (modelData.from.name || modelData.from.email) : "?"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 13; font.weight: 600
                    }
                    Text {
                        renderType: Text.NativeRendering
                        text: modelData.from && modelData.from.name ? "<" + modelData.from.email + ">" : ""
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        renderType: Text.NativeRendering
                        text: Backend.fmtDate(modelData.date)
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // attachment chips
                Flow {
                    width: parent.width
                    spacing: 6
                    visible: (modelData.attachments || []).length > 0
                    Repeater {
                        model: modelData.attachments || []
                        Rectangle {
                            required property var modelData
                            width: chipText.implicitWidth + 20; height: 22
                            radius: 11; color: Theme.surface2
                            Text {
                                id: chipText
                                renderType: Text.NativeRendering
                                anchors.centerIn: parent
                                text: "󰁦 " + (modelData.name || "attachment")
                                color: Theme.fg_secondary
                                font.family: Theme.fontFamily; font.pixelSize: 11
                            }
                        }
                    }
                }

                Text {
                    renderType: Text.NativeRendering
                    width: parent.width
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    text: modelData.bodyRich || ""
                    linkColor: Theme.sky
                    color: Theme.fg_secondary
                    font.family: Theme.fontFamily
                    font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 13
                    onLinkActivated: link => Qt.openUrlExternally(link)
                }
            }
        }
    }

    Text {
        renderType: Text.NativeRendering
        anchors.centerIn: parent
        visible: list.count === 0
        text: "loading…"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13
    }
}
