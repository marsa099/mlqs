import QtQuick
import QtQuick.Controls
import "."
import QsLib

// New-event overlay: MailComposer's picker grammar, calendar fields.
// Ctrl+Enter creates, Esc discards.
Rectangle {
    id: comp
    visible: false
    anchors.centerIn: parent
    width: Math.min(parent.width - 120, 560)
    height: 434
    radius: Theme.radiusCard
    color: Theme.bg_alt
    border.width: 1
    border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    property int sel: 0   // title · date · start · duration · attendees · location
    readonly property var fields: [titleField, dateField, startField, durField, attField, locField]
    readonly property bool editing: fields.some(f => f.input.activeFocus)
    function focusSel() { fields[sel].input.forceActiveFocus() }
    property bool meet: true
    signal closed()

    // attendee autocomplete reuses the harvested-contacts store
    property var acItems: []
    property int acSel: 0
    property string acToken: ""
    function acUpdate() {
        const tok = attField.text.split(",").pop().trim()
        acToken = tok
        if (tok.length >= 1 && attField.input.activeFocus) Backend.queryContacts(tok)
        else acItems = []
    }
    function acAccept() {
        if (acItems.length === 0) return
        const c = acItems[acSel]
        const parts = attField.text.split(",")
        parts[parts.length - 1] = " " + c.email
        attField.text = parts.join(",").replace(/^ /, "") + ", "
        attField.input.cursorPosition = attField.text.length
        acItems = []
    }
    Connections {
        target: Backend
        function onContactsResult(items, query) {
            if (query !== comp.acToken || !comp.visible) return
            comp.acItems = items; comp.acSel = 0
        }
        function onAccountCalendarsChanged() {
            if (!comp.visible) return
            const i = Backend.accountCalendars.findIndex(c => c.primary)
            comp.calSel = i >= 0 ? i : 0
        }
    }

    // target calendar: cycles through the account's calendars; read-only
    // ones are shown (so shared calendars are discoverable) but refuse create
    property int calSel: 0
    readonly property var cals: Backend.accountCalendars
    readonly property var curCal: cals.length > 0 ? cals[Math.min(calSel, cals.length - 1)] : null
    readonly property bool curCalWritable: !curCal || curCal.role === "owner" || curCal.role === "writer"
    function cycleCal(d) {
        if (cals.length > 0) calSel = (calSel + (d || 1) + cals.length) % cals.length
    }

    function composeNew() {
        const now = new Date()
        // next full half-hour
        now.setMinutes(now.getMinutes() + 30 - (now.getMinutes() % 30), 0, 0)
        titleField.text = ""; attField.text = ""; locField.text = ""
        dateField.text = Qt.formatDate(now, "yyyy-MM-dd")
        startField.text = Qt.formatTime(now, "hh:mm")
        durField.text = "30"
        meet = true
        sel = 0
        calSel = 0
        Backend.requestCalendars()
        visible = true
        titleField.input.forceActiveFocus()
    }

    function doCreate() {
        if (titleField.text.trim() === "") { Backend.toast("no title"); return }
        if (!curCalWritable) { Backend.toast((curCal ? curCal.name : "calendar") + " is read-only for you"); return }
        const start = dateField.text.trim() + " " + startField.text.trim()
        const mins = parseInt(durField.text, 10) || 30
        const sd = new Date(dateField.text.trim() + "T" + startField.text.trim())
        if (isNaN(sd.getTime())) { Backend.toast("bad date/time"); return }
        const ed = new Date(sd.getTime() + mins * 60000)
        Backend.createEvent({
            title: titleField.text.trim(),
            start: start,
            end: Qt.formatDate(ed, "yyyy-MM-dd") + " " + Qt.formatTime(ed, "hh:mm"),
            attendees: attField.text, location: locField.text.trim(),
            calId: curCal && !curCal.primary ? curCal.id : "",
            meet: meet && attField.text.trim() !== ""
        })
        close()
    }

    function close() { visible = false; acItems = []; closed() }

    function handleKeys(e) {
        const ctrl = e.modifiers & Qt.ControlModifier
        if (acItems.length > 0 && attField.input.activeFocus) {
            if (e.key === Qt.Key_Escape) { acItems = []; e.accepted = true; return true }
            if (e.key === Qt.Key_Tab || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                acAccept(); e.accepted = true; return true
            }
            if (ctrl && (e.key === Qt.Key_N || e.key === Qt.Key_J)) {
                acSel = Math.min(acItems.length - 1, acSel + 1); e.accepted = true; return true
            }
            if (ctrl && (e.key === Qt.Key_P || e.key === Qt.Key_K)) {
                acSel = Math.max(0, acSel - 1); e.accepted = true; return true
            }
        }
        if (e.key === Qt.Key_Escape) { compKeys.forceActiveFocus(); e.accepted = true; return true }
        if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { doCreate(); e.accepted = true; return true }
        // Tab walks every row including the calendar picker — it's not a text
        // field, so Qt's default tab chain skips it (the mouse-only bug)
        if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) {
            const d = e.key === Qt.Key_Backtab ? -1 : 1
            const cur = fields.findIndex(f => f.input.activeFocus)
            sel = ((cur < 0 ? sel : cur) + d + fields.length + 1) % (fields.length + 1)
            if (sel === fields.length) compKeys.forceActiveFocus()   // calendar row: ↵ cycles
            else focusSel()
            e.accepted = true; return true
        }
        return false
    }

    component LabeledField: Rectangle {
        property alias text: input.text
        property alias input: input
        property string label: ""
        property int idx: 0
        property string hint: ""
        width: parent.width; height: 34
        radius: Theme.radiusSm
        color: Theme.mode === "light" ? Theme.bg : Theme.surface2
        border.width: 1
        border.color: input.activeFocus ? (Theme.mode === "light" ? Theme.fg : "#FFFFFF")
                    : (comp.sel === idx && !comp.editing) ? Theme.fg_muted : Theme.hairline
        Row {
            anchors.fill: parent; anchors.leftMargin: 10
            spacing: 8
            Text {
                text: label; color: Theme.fg_muted
                width: 66
                font.family: Theme.fontFamily; font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
            }
            TextField {
                id: input
                width: parent.width - 84; height: parent.height
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.fg
                placeholderText: hint
                placeholderTextColor: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 13
                background: null
                onTextChanged: if (parent.parent.idx === 4 && activeFocus) comp.acUpdate()
                onActiveFocusChanged: if (!activeFocus) comp.acItems = []
                Keys.onPressed: e => comp.handleKeys(e)
            }
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        Text {
            text: "New event · " + Backend.currentAccount
            color: Theme.fg
            font.family: Theme.fontFamily; font.pixelSize: 14; font.weight: 600
        }

        LabeledField { id: titleField; label: "Title"; idx: 0 }
        LabeledField { id: dateField; label: "Date"; idx: 1; hint: "YYYY-MM-DD" }
        LabeledField { id: startField; label: "Start"; idx: 2; hint: "HH:MM" }
        LabeledField { id: durField; label: "Minutes"; idx: 3; hint: "30" }
        LabeledField { id: attField; label: "Invite"; idx: 4; hint: "emails, comma-separated" }
        LabeledField { id: locField; label: "Where"; idx: 5 }

        // target calendar: ↵/i cycles (not a text field)
        Rectangle {
            width: parent.width; height: 34
            radius: Theme.radiusSm
            color: Theme.mode === "light" ? Theme.bg : Theme.surface2
            border.width: 1
            border.color: (comp.sel === 6 && !comp.editing) ? Theme.fg_muted : Theme.hairline
            Row {
                anchors.fill: parent; anchors.leftMargin: 10
                spacing: 8
                Text {
                    text: "Calendar"; color: Theme.fg_muted
                    width: 66
                    font.family: Theme.fontFamily; font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: comp.curCal ? (comp.curCal.primary ? Backend.currentAccount + " (primary)" : comp.curCal.name)
                                        + (comp.curCalWritable ? "" : "  · read-only") : "primary"
                    color: comp.curCalWritable ? Theme.fg : Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 13
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: comp.cals.length > 1
                    text: "↵ cycles"
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 11
                }
            }
            TapHandler { onTapped: comp.cycleCal(1) }
        }

        Row {
            spacing: 8
            Rectangle {
                width: 16; height: 16; radius: 5
                anchors.verticalCenter: parent.verticalCenter
                color: comp.meet ? Theme.cursor : Theme.bg
                border.width: 1
                border.color: comp.meet ? Theme.cursor : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.25)
                Icon {
                    visible: comp.meet
                    anchors.centerIn: parent; width: 10; height: 10
                    name: "check"; color: Theme.ink
                }
                TapHandler { onTapped: comp.meet = !comp.meet }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Google Meet (when inviting)  ·  m toggles"
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
            }
        }
    }

    Rectangle {
        visible: comp.acItems.length > 0 && attField.input.activeFocus
        z: 50
        x: 16
        y: attField.mapToItem(comp, 0, attField.height).y + 4
        width: 360
        height: Math.min(comp.acItems.length, 6) * 32 + 8
        radius: 9
        color: Theme.bg_alt
        border.width: 1
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)
        Column {
            anchors.fill: parent; anchors.margins: 4
            Repeater {
                model: comp.acItems
                Rectangle {
                    required property var modelData
                    required property int index
                    width: parent.width; height: 32; radius: 7
                    color: index === comp.acSel
                         ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08) : "transparent"
                    border.width: 1
                    border.color: index === comp.acSel ? Theme.hairline : "transparent"
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 10; spacing: 8
                        Text { anchors.verticalCenter: parent.verticalCenter
                               text: modelData.name || modelData.email; color: Theme.fg
                               font.family: Theme.fontFamily; font.pixelSize: 13 }
                        Text { anchors.verticalCenter: parent.verticalCenter
                               visible: !!modelData.name
                               text: modelData.email; color: Theme.fg_muted
                               font.family: Theme.fontFamily; font.pixelSize: 11 }
                    }
                    TapHandler { onTapped: { comp.acSel = index; comp.acAccept() } }
                }
            }
        }
    }

    Item {
        id: compKeys
        anchors.fill: parent
        focus: comp.visible && !comp.editing
        Keys.onPressed: e => {
            const ctrl = e.modifiers & Qt.ControlModifier
            if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { comp.doCreate(); e.accepted = true; return }
            switch (e.key) {
            case Qt.Key_J: comp.sel = Math.min(comp.fields.length, comp.sel + 1); break
            case Qt.Key_K: comp.sel = Math.max(0, comp.sel - 1); break
            case Qt.Key_M: comp.meet = !comp.meet; break
            case Qt.Key_I:
            case Qt.Key_Return:
            case Qt.Key_Enter:
                if (comp.sel === comp.fields.length) comp.cycleCal(1)
                else comp.focusSel()
                break
            case Qt.Key_Escape:
            case Qt.Key_Q: comp.close(); break
            default: return
            }
            e.accepted = true
        }
    }

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 34; color: Theme.surface0
        radius: Theme.radius
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            component CCap: Rectangle {
                property alias text: t.text
                width: Math.max(t.implicitWidth + 12, 22); height: 22; radius: 7
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.mode === "light" ? Theme.bg : Theme.surface2
                border.width: 1; border.color: Theme.hairline
                Text { id: t; anchors.centerIn: parent
                       color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                       font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500 }
            }
            component CLbl: Text {
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                font.family: Theme.fontFamily; font.pixelSize: 11
            }
            CCap { text: "j" } CCap { text: "k" } CLbl { text: "field" }
            Item { width: 8; height: 1 }
            CCap { text: "i" } CLbl { text: "edit" }
            Item { width: 8; height: 1 }
            CCap { text: "m" } CLbl { text: "meet" }
            Item { width: 8; height: 1 }
            CCap { text: "⌃↵" } CLbl { text: "create" }
            Item { width: 8; height: 1 }
            CCap { text: "esc" } CLbl { text: "close" }
        }
    }
}
