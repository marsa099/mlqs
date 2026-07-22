import QtQuick
import QtQuick.Controls
import Quickshell.Io
import "."
import QsLib

// Compose / reply overlay. Ctrl+Enter sends, Esc discards,
// Ctrl+O attaches the file path currently on the clipboard.
Rectangle {
    id: comp
    visible: false
    anchors.centerIn: parent
    width: Math.min(parent.width - 120, 760)
    height: Math.min(parent.height - 100, 640)
    radius: Theme.radiusCard
    color: Theme.bg_alt
    border.width: 1
    border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    property int sel: 0   // 0 to · 1 cc · 2 subject · 3 body
    // recipient autocomplete (chat Autocomplete grammar: fg tint + hairpin)
    property var acItems: []
    property int acSel: 0
    property string acToken: ""
    property var acInput: null
    readonly property bool acOpen: acItems.length > 0 && acInput !== null
    function acUpdate(input) {
        acInput = input
        const tok = input.text.split(",").pop().trim()
        acToken = tok
        if (tok.length >= 1 && input.activeFocus) Backend.queryContacts(tok)
        else acItems = []
    }
    function acClose() { acItems = []; acInput = null }
    function acAccept() {
        if (!acOpen) return
        const c = acItems[acSel]
        const parts = acInput.text.split(",")
        parts[parts.length - 1] = " " + c.email
        acInput.text = parts.join(",").replace(/^ /, "") + ", "
        acInput.cursorPosition = acInput.text.length
        acClose()
    }
    Connections {
        target: Backend
        function onContactsResult(items, query) {
            if (query !== comp.acToken || !comp.visible) return
            comp.acItems = items; comp.acSel = 0
        }
    }
    readonly property bool editing: toField.input.activeFocus || ccField.input.activeFocus
                                    || subjField.input.activeFocus || bodyArea.activeFocus
    function focusSel() {
        [toField.input, ccField.input, subjField.input, bodyArea][sel].forceActiveFocus()
    }
    property string mode: "new"      // "new" | "reply" | "forward"
    property string replyToId: ""
    property string convId: ""
    property string forwardId: ""
    property string forwardInfo: ""
    property var paths: []
    signal closed()

    function composeNew() {
        mode = "new"; replyToId = ""; convId = ""; forwardId = ""; paths = []
        toField.text = ""; ccField.text = ""; subjField.text = ""; bodyArea.text = ""
        sel = 0
        visible = true
        toField.input.forceActiveFocus()
    }

    // mailto: from a message body — recipient prefilled, cursor on subject
    function composeTo(addr) {
        composeNew()
        toField.text = addr
        subjField.input.forceActiveFocus()
    }

    // forward a message: daemon quotes the original + re-attaches its files
    function forward(m) {
        if (!m || !m.id) return
        mode = "forward"; replyToId = ""; forwardId = m.id
        convId = Backend.openConvId; paths = []
        toField.text = ""; ccField.text = ""; bodyArea.text = ""
        const subj = m.subject || Backend.openConvSubject
        subjField.text = subj.match(/^fwd:/i) ? subj : "Fwd: " + subj
        const atts = (m.attachments || []).filter(a => a.name).length
        forwardInfo = "↪ forwarding: " + (m.from ? (m.from.name || m.from.email) : "")
                    + (atts > 0 ? "  · " + atts + " attachment" + (atts > 1 ? "s" : "") : "")
        sel = 0
        visible = true
        toField.input.forceActiveFocus()
    }

    // reply to the newest message; all=true adds every recipient minus self.
    // Reply-To wins over From (RFC 5322) — list servers depend on it.
    function reply(all) {
        const msgs = Backend.messages
        if (msgs.length === 0) return
        const m = msgs[msgs.length - 1]
        mode = "reply"; replyToId = m.id; convId = Backend.openConvId; forwardId = ""; paths = []
        const sender = (m.replyTo && m.replyTo.length) ? m.replyTo : (m.from ? [m.from] : [])
        toField.text = [...new Set(sender.map(a => a.email).filter(e => e))].join(", ")
        let cc = []
        if (all) {
            const self = (Backend.workspaces.find(w => w.id === Backend.currentAccount) || {}).email || ""
            const senderSet = sender.map(a => a.email)
            const rest = (m.to || []).concat(m.cc || [])
                .map(a => a.email).filter(e => e && e !== self && senderSet.indexOf(e) < 0)
            cc = [...new Set(rest)]
        }
        ccField.text = cc.join(", ")
        const subj = m.subject || Backend.openConvSubject
        subjField.text = subj.match(/^re:/i) ? subj : "Re: " + subj
        bodyArea.text = ""
        sel = 3
        visible = true
        bodyArea.forceActiveFocus()
    }

    function doSend() {
        if (toField.text.trim() === "") { Backend.toast("no recipient"); return }
        Backend.sendMail({
            to: toField.text, cc: ccField.text, subject: subjField.text,
            body: bodyArea.text, replyTo: replyToId, conv: convId,
            forward: forwardId, paths: paths
        })
        close()
    }

    function close() { visible = false; closed() }

    function attachClipboardPath() { clipPath.running = true }
    Process {
        id: clipPath
        command: ["wl-paste", "-n"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim()
                if (p.startsWith("/") || p.startsWith("~")) {
                    comp.paths = comp.paths.concat([p])
                } else Backend.toast("clipboard is not a file path")
            }
        }
    }

    // shared keys for every field in the composer
    function handleKeys(e) {
        const ctrl = e.modifiers & Qt.ControlModifier
        if (acOpen) {
            if (e.key === Qt.Key_Escape) { acClose(); e.accepted = true; return true }
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
        if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { doSend(); e.accepted = true; return true }
        if (ctrl && e.key === Qt.Key_O) { attachClipboardPath(); e.accepted = true; return true }
        return false
    }

    component LabeledField: Rectangle {
        property alias text: input.text
        property alias input: input
        property string label: ""
        property int idx: 0
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
                width: 56
                font.family: Theme.fontFamily; font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
            }
            TextField {
                id: input
                width: parent.width - 74; height: parent.height
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: 13
                background: null
                onTextChanged: if (parent.parent.idx < 2 && activeFocus) comp.acUpdate(input)
                onActiveFocusChanged: if (!activeFocus) comp.acClose()
                Keys.onPressed: e => comp.handleKeys(e)
            }
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        Text {
            text: comp.mode === "reply" ? "Reply" : comp.mode === "forward" ? "Forward" : "New message"
            color: Theme.fg
            font.family: Theme.fontFamily; font.pixelSize: 14; font.weight: 600
        }

        Text {
            visible: comp.mode === "forward"
            width: parent.width
            text: comp.forwardInfo
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: 12
            elide: Text.ElideRight
        }

        LabeledField { id: toField; label: "To"; idx: 0 }
        LabeledField { id: ccField; label: "Cc"; idx: 1 }
        LabeledField { id: subjField; label: "Subject"; idx: 2 }

        Rectangle {
            width: parent.width
            height: parent.height - y - (attachRow.visible ? 34 : 0) - 34
            radius: Theme.radiusSm
            color: Theme.mode === "light" ? Theme.bg : Theme.surface1
            border.width: 1
            border.color: bodyArea.activeFocus ? (Theme.mode === "light" ? Theme.fg : "#FFFFFF")
                        : (comp.sel === 3 && !comp.editing) ? Theme.fg_muted : Theme.hairline
            Flickable {
                id: bodyFlick
                anchors.fill: parent; anchors.margins: 10
                contentHeight: bodyArea.implicitHeight; clip: true
                function ensureVisible(r) {
                    if (contentY >= r.y) contentY = r.y
                    else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
                }
                TextArea {
                    id: bodyArea
                    width: bodyFlick.width
                    onCursorRectangleChanged: bodyFlick.ensureVisible(cursorRectangle)
                    wrapMode: TextArea.Wrap
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: 13
                    background: null
                    Keys.onPressed: e => comp.handleKeys(e)
                }
            }
        }

        Row {
            id: attachRow
            visible: comp.paths.length > 0
            spacing: 6
            Repeater {
                model: comp.paths
                Rectangle {
                    required property var modelData
                    required property int index
                    width: chip.implicitWidth + 26; height: 22
                    radius: 11; color: Theme.surface2
                    Text {
                        id: chip
                        anchors.left: parent.left; anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰁦 " + modelData.split("/").pop()
                        color: Theme.fg_secondary
                        font.family: Theme.fontFamily; font.pixelSize: 11
                    }
                    TapHandler { onTapped: comp.paths = comp.paths.filter((_, i) => i !== index) }
                }
            }
        }

    }

    Rectangle {
        visible: comp.acOpen
        z: 50
        x: 16
        y: comp.acInput ? comp.acInput.parent.parent.mapToItem(comp, 0, comp.acInput.parent.parent.height).y + 4 : 0
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
            if (ctrl && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { comp.doSend(); e.accepted = true; return }
            if (ctrl && e.key === Qt.Key_O) { comp.attachClipboardPath(); e.accepted = true; return }
            switch (e.key) {
            case Qt.Key_J: comp.sel = Math.min(3, comp.sel + 1); break
            case Qt.Key_K: comp.sel = Math.max(0, comp.sel - 1); break
            case Qt.Key_I:
            case Qt.Key_Return:
            case Qt.Key_Enter: comp.focusSel(); break
            case Qt.Key_Escape:
            case Qt.Key_Q: comp.close(); break
            default: return
            }
            e.accepted = true
        }
    }

    // picker chin: same band + keycap grammar as every other picker
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
            CCap { text: "⌃↵" } CLbl { text: "send" }
            Item { width: 8; height: 1 }
            CCap { text: "⌃o" } CLbl { text: "attach" }
            Item { width: 8; height: 1 }
            CCap { text: "esc" } CLbl { text: "close" }
        }
    }
}
