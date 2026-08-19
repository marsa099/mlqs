import QtQuick
import "."
import QsLib

// ctrl+o on a calendar event: its full detail in a modal (the shared Modal
// shell — scroll/keys/chrome there), so you can read everything without
// joining. ↵ joins the meeting when there is one; esc closes.
Modal {
    id: em
    property var ev: null
    panelWidth: Math.round(Math.min(900, em.width - 100))
    maxHeightFrac: 0.60
    panelColor: Theme.bg   // pickers/detail panels use bg so selection reads

    property bool attendeesExpanded: false
    function showEvent(e) { if (!e) return; ev = e; attendeesExpanded = false; show() }
    readonly property var attendees: (ev && ev.attendeesJson) ? JSON.parse(ev.attendeesJson) : []
    readonly property var acceptedAttendees: attendees.filter(a => a.status === "accepted")
    // collapsed preview: the ten first accepted people — or, before anyone has
    // accepted, the ten first invited, so the list never renders empty
    readonly property var previewAttendees: (acceptedAttendees.length > 0 ? acceptedAttendees : attendees).slice(0, 10)
    readonly property var visibleAttendees: attendeesExpanded ? attendees : previewAttendees

    onKeyPressed: event => {
        if (event.key === Qt.Key_A && !(event.modifiers & Qt.ControlModifier)) {
            attendeesExpanded = !attendeesExpanded
            event.accepted = true
        }
    }

    onAccepted: { if (ev && ev.meetLink) Qt.openUrlExternally(ev.meetLink); close() }

    header: Column {
        width: parent.width; spacing: 3
        Text {
            width: parent.width
            text: em.ev ? em.ev.title : ""
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 16; font.weight: 600; wrapMode: Text.WordWrap
        }
        Text {
            width: parent.width
            text: em.ev ? (em.ev.dayKey + " · " + em.ev.timeStr) : ""
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 12
        }
    }

    footer: Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 5
        KeyCap { visible: em.ev && em.ev.meetLink !== ""; anchors.verticalCenter: parent.verticalCenter; small: true; text: "↵" }
        CapLabel { visible: em.ev && em.ev.meetLink !== ""; anchors.verticalCenter: parent.verticalCenter; text: "join" }
        Item { visible: em.ev && em.ev.meetLink !== ""; width: 10; height: 1 }
        KeyCap { visible: em.attendees.length > 0; anchors.verticalCenter: parent.verticalCenter; small: true; text: "a" }
        CapLabel { visible: em.attendees.length > 0; anchors.verticalCenter: parent.verticalCenter
                   text: em.attendeesExpanded ? "collapse attendees" : "all attendees" }
        Item { visible: em.attendees.length > 0; width: 10; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "close" }
    }

    Column {
        width: parent.width
        spacing: 9

        Text {
            visible: em.ev && em.ev.location !== "" && em.ev.location.indexOf("http") !== 0
            width: parent.width
            text: em.ev ? em.ev.location : ""
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; wrapMode: Text.WordWrap
        }

        Text {
            visible: em.ev && em.ev.organizer !== ""
            text: "organized by " + (em.ev ? em.ev.organizer : "")
            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12
        }

        // Compact by default: ten accepted people, wrapping across the available
        // width. `a` expands all response states without making every person a row.
        Column {
            width: parent.width; spacing: 6
            visible: em.attendees.length > 0
            Flow {
                width: parent.width
                spacing: 12
                Repeater {
                    model: em.visibleAttendees
                    delegate: Row {
                        required property var modelData
                        spacing: 5
                        height: 18
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7; height: 7; radius: 3.5
                            readonly property string st: modelData.status || ""
                            color: st === "accepted" ? Theme.green
                                 : st === "tentative" ? Theme.yellow
                                 : st === "declined" ? Theme.red : "transparent"
                            border.width: st === "needsAction" ? 1.2 : 0
                            border.color: Theme.yellow
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: (modelData.name && modelData.name !== "" ? modelData.name : modelData.email)
                                  + (modelData.self ? " (you)" : "")
                            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12
                        }
                    }
                }
            }
            Text {
                visible: em.attendees.length > em.previewAttendees.length
                text: em.attendeesExpanded ? "show fewer"
                    : "+" + (em.attendees.length - em.previewAttendees.length) + " more"
                color: Theme.sky; font.family: Theme.fontFamily; font.pixelSize: 11
                TapHandler { onTapped: em.attendeesExpanded = !em.attendeesExpanded }
            }
        }

        // Meeting link as TEXT — click (or ↵) to join; never auto-opened.
        Text {
            visible: em.ev && em.ev.meetLink !== ""
            width: parent.width
            text: "join: " + (em.ev ? em.ev.meetLink : "")
            color: Theme.sky; font.family: Theme.fontFamily; font.pixelSize: 12
            elide: Text.ElideRight
            TapHandler { onTapped: { if (em.ev) Qt.openUrlExternally(em.ev.meetLink) } }
        }
        Text {
            visible: em.ev && em.ev.htmlLink !== ""
            width: parent.width
            text: "open in calendar"
            color: Theme.sky; font.family: Theme.fontFamily; font.pixelSize: 12
            TapHandler { onTapped: { if (em.ev) Qt.openUrlExternally(em.ev.htmlLink) } }
        }

        Rectangle {
            visible: em.ev && em.ev.description !== ""
            width: parent.width; height: 1; color: Theme.hairline
        }
        Text {
            visible: em.ev && em.ev.description !== ""
            width: parent.width
            text: em.ev ? em.ev.description : ""
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; wrapMode: Text.WordWrap
        }
    }
}
