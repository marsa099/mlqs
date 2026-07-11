import QtQuick
import "."
import QsLib

// Agenda pane: merged events across accounts, grouped by day, in the same
// canvas + floating-card language as the mail index.
Rectangle {
    id: cal
    color: "transparent"
    property bool active: true

    function move(d) {
        if (list.count === 0) return
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
    }
    function page(d) { move(d * Math.max(3, Math.floor(list.height / 44 / 2))) }
    function toTop() { list.currentIndex = 0 }
    function toEnd() { list.currentIndex = list.count - 1 }
    function current() {
        return list.currentIndex >= 0 && list.currentIndex < list.count
            ? Backend.events.get(list.currentIndex) : null
    }
    // enter: join the meeting when there is one, else open in the browser
    function open() {
        const ev = current()
        if (!ev) return
        const link = ev.meetLink || ev.htmlLink
        if (link) Qt.openUrlExternally(link)
    }
    function openBrowser() {
        const ev = current()
        if (ev && ev.htmlLink) Qt.openUrlExternally(ev.htmlLink)
    }
    function rsvp(status) {
        const ev = current()
        if (ev) Backend.rsvp(ev, status)
    }

    function cycleSpan() {
        Backend.setAgendaSpan(Backend.agendaDays === 1 ? 7 : Backend.agendaDays === 7 ? 31 : 1)
    }

    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52; color: "transparent"
        Text {
            renderType: Text.NativeRendering
            anchors.left: parent.left; anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: "Calendar" + (Backend.loadingAgenda ? "  · loading…" : "")
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 14; font.weight: 600
        }
        // span filter: same pill-tab grammar as the sidebar account tabs
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Repeater {
                model: [{ label: "day", days: 1 }, { label: "week", days: 7 }, { label: "month", days: 31 }]
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: Backend.agendaDays === modelData.days
                    height: 26; radius: 13
                    width: spanLbl.implicitWidth + 22
                    color: on ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10)
                         : spanHov.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: on ? Theme.hairline : "transparent"
                    HoverHandler { id: spanHov }
                    Text {
                        id: spanLbl
                        renderType: Text.NativeRendering
                        anchors.centerIn: parent
                        text: modelData.label
                        color: on ? Theme.fg : Theme.dimmedFg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 12; font.weight: on ? 500 : 400
                    }
                    TapHandler { onTapped: Backend.setAgendaSpan(modelData.days) }
                }
            }
        }
    }

    Rectangle {
        id: card
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                  topMargin: 6; leftMargin: 8; rightMargin: 14; bottomMargin: 14 }
        radius: Theme.radius
        color: Theme.bg
    }

    ListView {
        id: list
        anchors { fill: card; topMargin: 8; bottomMargin: 8 }
        model: Backend.events
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 60
        preferredHighlightBegin: 80
        preferredHighlightEnd: height - 80
        highlightRangeMode: ListView.ApplyRange

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

        section.property: "dayKey"
        section.delegate: Item {
            required property string section
            width: list.width; height: 40
            Text {
                renderType: Text.NativeRendering
                anchors.left: parent.left; anchors.leftMargin: 40
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                text: section.toUpperCase()
                color: Theme.fg_muted; font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 11; font.weight: 500; font.letterSpacing: 1.2
            }
        }

        delegate: Item {
            id: row
            required property int index
            required property string eid
            required property string title
            required property string location
            required property string timeStr
            required property string meetLink
            required property string myStatus
            required property string account
            required property string organizer
            required property int attendeeCount
            width: list.width; height: 44
            readonly property bool cursor: index === list.currentIndex
            readonly property bool declined: myStatus === "declined"

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: cal.active ? 36 : 8
                anchors.rightMargin: 8
                anchors.topMargin: 3; anchors.bottomMargin: 3
                radius: height / 2
                color: row.cursor && cal.active ? Theme.selection
                     : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.03)
                border.width: row.cursor && cal.active ? 1 : 0
                border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.35)
            }

            Item {
                width: 22; height: parent.height
                anchors.left: parent.left; anchors.leftMargin: 4
                visible: cal.active
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

            // RSVP state dot: green accepted, hollow yellow needs answer,
            // filled yellow tentative, red declined
            Rectangle {
                id: statusDot
                anchors.left: parent.left; anchors.leftMargin: cal.active ? 56 : 28
                anchors.verticalCenter: parent.verticalCenter
                width: 9; height: 9; radius: 5
                color: row.myStatus === "accepted" ? Theme.green
                     : row.myStatus === "tentative" ? Theme.yellow
                     : row.declined ? Theme.red : "transparent"
                border.width: row.myStatus === "needsAction" ? 1.5 : 0
                border.color: Theme.yellow
            }

            Text {
                id: timeText
                renderType: Text.NativeRendering
                anchors.left: parent.left; anchors.leftMargin: cal.active ? 78 : 50
                anchors.verticalCenter: parent.verticalCenter
                width: 92
                text: row.timeStr
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
                font.features: ({ "tnum": 1 })
            }

            Icon {
                id: meetIcon
                visible: row.meetLink !== ""
                anchors.left: timeText.right; anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                width: 13; height: 13
                name: "camera-2"
                color: Theme.fg_muted
            }

            Text {
                renderType: Text.NativeRendering
                anchors.left: timeText.right; anchors.leftMargin: 26
                anchors.right: acctText.left; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: row.title
                      + (row.location !== "" && row.location.indexOf("http") !== 0 ? "   · " + row.location : "")
                color: row.declined ? Theme.fg_muted : Theme.fg
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.strikeout: row.declined
                elide: Text.ElideRight
            }

            Text {
                id: acctText
                renderType: Text.NativeRendering
                anchors.right: parent.right; anchors.rightMargin: 30
                anchors.verticalCenter: parent.verticalCenter
                text: (row.attendeeCount > 1 ? row.attendeeCount + " ppl · " : "") + row.account
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 11
            }

            TapHandler {
                onTapped: { list.currentIndex = index; cal.open() }
            }
        }
    }

    Text {
        renderType: Text.NativeRendering
        anchors.centerIn: parent
        visible: list.count === 0 && !Backend.loadingAgenda
        text: "no upcoming events"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13
    }
}
