import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import "."

Rectangle {
    id: cv
    color: Theme.bg

    function move(d) {
        if (list.count === 0) return
        cancelHints()
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
        // scroll only when the target's start is off-screen — a focus move
        // between visible messages must not shift the view
        const it = list.itemAtIndex(list.currentIndex)
        if (!it || it.y < list.contentY - 2 || it.y > list.contentY + list.height - 40)
            list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
    }
    function clampY(y) {
        return Math.max(list.originY, Math.min(list.originY + list.contentHeight - list.height, y))
    }
    // picker-grain j/k: move to the next/prev message as soon as the current
    // one's relevant edge is visible; scroll within it while it isn't. Long
    // messages read through, short ones navigate row-to-row like a picker.
    function scrollLine(d) {
        const it = list.itemAtIndex(list.currentIndex)
        if (!it) { move(d); return }
        if (d > 0) {
            const bottomVisible = it.y + it.height <= list.contentY + list.height + 2
            if (bottomVisible) { move(1); return }
        } else {
            const topVisible = it.y >= list.contentY - 2
            if (topVisible) { move(-1); return }
        }
        list.contentY = clampY(list.contentY + d * 90)
    }
    function scroll(d) { list.contentY = clampY(list.contentY + d * list.height / 2) }
    function toTop() { list.contentY = list.originY; list.currentIndex = 0 }
    function toEnd() { list.contentY = clampY(list.originY + list.contentHeight); list.currentIndex = list.count - 1 }
    // newest message focused, scrolled to its TOP (not its end — a long
    // newsletter must open at the start, not the footer)
    function focusNewest() {
        list.currentIndex = list.count - 1
        list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
    }
    signal exitInsert()
    readonly property bool replyHasFocus: replyInput.activeFocus

    // inline reply: target message (R picks one; default newest) + reply-all
    property string replyTargetId: ""
    property bool replyAll: true
    readonly property string myEmail: {
        const w = Backend.workspaces.find(x => x.id === Backend.currentAccount)
        return w && w.email ? w.email.toLowerCase() : ""
    }
    function targetMsg() {
        return Backend.messages.find(m => m.id === cv.replyTargetId)
            || Backend.messages[Backend.messages.length - 1] || null
    }
    function replyTargetName() {
        const t = targetMsg()
        if (!t || !t.from) return ""
        return t.from.name || t.from.email || ""
    }
    function focusReply() { replyInput.forceActiveFocus() }
    function replyToFocused() {
        const m = Backend.messages[list.currentIndex]
        if (!m) return
        replyTargetId = m.id
        focusReply()
    }
    function recipientLine(m) {
        const fmt = a => (a.email && a.email.toLowerCase() === cv.myEmail) ? "me" : (a.name || a.email)
        const tos = (m.to || []).map(fmt)
        const ccs = (m.cc || []).map(fmt)
        let s = tos.length ? "to " + tos.join(", ") : ""
        if (ccs.length) s += (s ? "   ·   " : "") + "cc " + ccs.join(", ")
        return s
    }
    // the literal recipient set a send would use — the footer displays this,
    // so "what does all mean here" is never a question
    function computeRecipients(all) {
        const t = targetMsg()
        if (!t) return { to: [], cc: [] }
        let to = []
        if (t.from && t.from.email && t.from.email.toLowerCase() !== cv.myEmail) to = [t.from.email]
        else to = (t.to || []).map(a => a.email).filter(e => e && e.toLowerCase() !== cv.myEmail)
        let cc = []
        if (all) {
            const rest = (t.to || []).concat(t.cc || []).map(a => a.email)
            cc = [...new Set(rest.filter(e => e && e.toLowerCase() !== cv.myEmail && to.indexOf(e) < 0))]
        }
        return { to: to, cc: cc }
    }
    function _nameOf(email) {
        const t = targetMsg()
        const pool = t ? [t.from].concat(t.to || [], t.cc || []) : []
        const hit = pool.find(a => a && a.email === email)
        return hit && hit.name ? hit.name : email
    }
    // legibility: primary recipient by name, everyone else is a count —
    // "LAST, FIRST" corporate names turn joined lists into token soup
    function replyPrimary() {
        const r = computeRecipients(replyAll)
        return r.to.length ? _nameOf(r.to[0]) : ""
    }
    function replyExtras() {
        const full = computeRecipients(true)
        return Math.max(0, full.to.length - 1) + full.cc.length
    }
    function sendReply() {
        const text = replyInput.text.trim()
        if (text === "") return
        const t = targetMsg()
        if (!t) return
        const r = computeRecipients(cv.replyAll)
        if (r.to.length === 0) { Backend.toast("no recipient"); return }
        let subj = t.subject || Backend.openConvSubject
        if (!/^re:/i.test(subj)) subj = "Re: " + subj
        Backend.sendMail({ to: r.to.join(", "), cc: r.cc.join(", "), subject: subj,
                           body: text, replyTo: t.id, conv: Backend.openConvId })
        replyInput.clear()
        cv.exitInsert()
    }

    function openCurrentHtml() {
        const m = Backend.messages[list.currentIndex]
        if (m && m.hasHtml) Backend.openHtml(m.id)
        else Backend.toast("no html body")
    }

    // vimium-style link hints: `f` injects [a]/[s]… labels before every link
    // and image in the FOCUSED message's rich text; typing a label opens it.
    property bool hinting: false
    property string hintBuf: ""
    property var hintTargets: []      // body urls, indexed after the chips
    property var hintLabels: []       // one namespace: chips first, then body
    property var hintAtts: []
    property int hintAttCount: 0
    property string hintMsgId: ""
    property string hintedHtml: ""
    property int hintIndex: -1

    readonly property var _hintRe: /<a\s[^>]*href="([^"]+)"[^>]*>|<img\s[^>]*src="(file:[^"]+)"[^>]*\/?>/gi

    property string hintBaseHtml: ""

    // Hint geometry: the hinted text reserves transparent inline gaps; an
    // invisible TextEdit mirror of the SAME document yields each gap's pixel
    // rect, and real KeyCap components draw there. Vector-crisp on every
    // display scale (raster grabs can't serve a 1.75x laptop + 1.0x monitor).
    property var hintRects: []
    // thin-space padding inside the cap; the trailing nbsp stays OUTSIDE it
    // as the right-hand gap (matching the word space on the left)
    function _reserved(label) {
        return '\u200B<span style="color:transparent;">&#8201;' + label + '&#8201;&nbsp;</span>'
    }
    function _renderHints() {
        let k = hintAttCount
        _hintRe.lastIndex = 0
        hintedHtml = hintBaseHtml.replace(_hintRe, tag => _reserved(hintLabels[k++]) + tag)
    }
    function startHints() {
        const m = Backend.messages[list.currentIndex]
        if (!m) return
        const atts = (m.attachments || []).filter(a => !a.shownInline)
        const html = m.bodyRich || ""
        const urls = []
        let match
        _hintRe.lastIndex = 0
        while ((match = _hintRe.exec(html)) !== null) urls.push(match[1] || match[2])
        const total = atts.length + urls.length
        if (total === 0) { Backend.toast("no links in message"); return }
        const A = "asdfghjkl"
        let labels
        if (total <= A.length) labels = A.slice(0, total).split("")
        else {
            labels = []
            for (let i = 0; i < A.length && labels.length < total; i++)
                for (let j = 0; j < A.length && labels.length < total; j++)
                    labels.push(A[i] + A[j])
        }
        hintAtts = atts; hintAttCount = atts.length; hintMsgId = m.id
        hintTargets = urls; hintLabels = labels
        hintBaseHtml = html.replace(/\u200B/g, "")
        hintRects = []
        hintIndex = list.currentIndex; hintBuf = ""
        _renderHints()
        hinting = true
    }
    function cancelHints() { hinting = false; hintBuf = ""; hintIndex = -1 }
    function hintKey(ch) {
        const buf = hintBuf + ch
        const exact = hintLabels.indexOf(buf)
        if (exact >= 0) {
            if (exact < hintAttCount) {
                const a = hintAtts[exact]
                cancelHints()
                Backend.openAttachment(hintMsgId, a)
                return
            }
            const url = hintTargets[exact - hintAttCount]
            cancelHints()
            Qt.openUrlExternally(url)
            return
        }
        if (hintLabels.some(l => l.indexOf(buf) === 0)) hintBuf = buf
        else cancelHints()
    }
    Connections {
        target: Backend
        function onMessagesChanged() {
            if (Backend.messages.length === 0) return
            const t = Backend.messages[Backend.messages.length - 1]
            cv.replyTargetId = t.id
            // default to reply-all when the newest message had an audience
            cv.replyAll = ((t.to || []).length + (t.cc || []).length) > 1
            Qt.callLater(cv.focusNewest)
        }
    }

    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        // 52px to match the sidebar's account-tab band — the hairline must
        // run continuously across both panels
        height: 52; color: Theme.bg
        Text {
            renderType: Text.NativeRendering
            anchors.left: parent.left; anchors.leftMargin: 14
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: Backend.openConvSubject + (cv.hinting ? "   󰌒 " + (cv.hintBuf || "type label…") : "")
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 14; font.weight: 600
            elide: Text.ElideRight
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
    }

    ListView {
        id: list
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: replyFooter.top; margins: 0 }
        model: Backend.messages
        clip: true
        spacing: 10
        topMargin: 12
        bottomMargin: 12
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

            // the picker cursor verbatim: warm Theme.selection fill + hairpin
            // (an fg tint reads cold gray and clashes with the family palette)
            readonly property bool multi: Backend.messages.length > 1
            readonly property bool focusedMsg: multi && index === list.currentIndex
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                radius: Theme.radius
                color: parent.focusedMsg ? Theme.selection : "transparent"
                border.width: 1
                border.color: parent.focusedMsg ? Theme.hairline : "transparent"
            }

            Column {
                id: content
                anchors.top: parent.top; anchors.topMargin: 12
                anchors.left: parent.left; anchors.leftMargin: 24
                // readable column: don't let body lines run the full window width
                width: Math.min(parent.width - 48, 820)
                spacing: 12

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
                    // unread-at-open marker (thread mark-read races the fetch,
                    // so these show what was new when you opened it)
                    Rectangle {
                        visible: modelData.unread === true
                        anchors.verticalCenter: parent.verticalCenter
                        height: 16; width: newLbl.implicitWidth + 12; radius: 8
                        color: Theme.cursor
                        Text {
                            id: newLbl
                            renderType: Text.NativeRendering
                            anchors.centerIn: parent
                            text: "new"
                            color: Theme.ink
                            font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: 600
                        }
                    }
                }

                Text {
                    renderType: Text.NativeRendering
                    width: parent.width
                    visible: text !== ""
                    text: cv.recipientLine(modelData)
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                // attachment chips — only cargo NOT already shown in the body
                Flow {
                    width: parent.width
                    spacing: 6
                    readonly property var chipAtts: (modelData.attachments || []).filter(a => !a.shownInline)
                    visible: chipAtts.length > 0
                    Repeater {
                        model: parent.chipAtts
                        Rectangle {
                            id: attChip
                            required property var modelData
                            required property int index
                            readonly property string msgId: parent.parent.parent.modelData.id
                            readonly property int msgIndex: parent.parent.parent.index
                            readonly property bool hinted: cv.hinting && msgIndex === cv.hintIndex
                                                           && index < cv.hintAttCount
                            readonly property string hintLabel: hinted ? cv.hintLabels[index] : ""
                            readonly property bool hintDim: hinted && cv.hintBuf !== ""
                                                            && hintLabel.indexOf(cv.hintBuf) !== 0
                            width: chipInner.implicitWidth + 20; height: 22
                            radius: 11
                            color: chipHov.hovered ? Theme.surface3 : Theme.surface2
                            Row {
                                id: chipInner
                                anchors.centerIn: parent
                                spacing: 6
                                Rectangle {
                                    visible: attChip.hinted
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(capT.implicitWidth + 10, 16); height: 16
                                    radius: 5
                                    border.width: attChip.hintDim ? 0 : 1
                                    border.color: Theme.hairline
                                    color: attChip.hintDim ? "transparent"
                                         : (Theme.mode === "light" ? Theme.bg : Theme.surface3)
                                    Text {
                                        id: capT
                                        renderType: Text.NativeRendering
                                        anchors.centerIn: parent
                                        text: attChip.hintLabel
                                        color: attChip.hintDim ? Theme.fg_muted : Theme.fg
                                        font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                                    }
                                }
                                Text {
                                    id: chipText
                                    renderType: Text.NativeRendering
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "󰁦 " + (attChip.modelData.name || "attachment")
                                    color: Theme.fg_secondary
                                    font.family: Theme.fontFamily; font.pixelSize: 11
                                }
                            }
                            HoverHandler { id: chipHov; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: Backend.openAttachment(attChip.msgId, attChip.modelData) }
                        }
                    }
                }

                Text {
                    id: bodyText
                    renderType: Text.NativeRendering
                    width: parent.width
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    text: (cv.hinting && index === cv.hintIndex) ? cv.hintedHtml : (modelData.bodyRich || "")
                    linkColor: Theme.sky
                    color: Theme.fg_secondary
                    font.family: Theme.fontFamily
                    font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 14
                    onLinkActivated: link => Qt.openUrlExternally(link)

                    // invisible layout twin: same document, same width, same
                    // font — its positionToRectangle locates the reserved gaps
                    TextEdit {
                        id: geom
                        visible: false
                        width: bodyText.width
                        textFormat: TextEdit.RichText
                        wrapMode: TextEdit.Wrap
                        font: bodyText.font
                        text: bodyText.text
                    }
                    function computeRects() {
                        if (!(cv.hinting && index === cv.hintIndex)) return
                        const doc = geom.getText(0, geom.length)
                        const rects = []
                        let from = 0
                        for (let k = 0; k < cv.hintLabels.length; k++) {
                            const p = doc.indexOf("\u200B", from)
                            if (p < 0) break
                            from = p + 1
                            const lab = cv.hintLabels[cv.hintAttCount + k]
                            const r1 = geom.positionToRectangle(p + 1)
                            const r2 = geom.positionToRectangle(p + 1 + lab.length + 2)
                            rects.push({ x: r1.x, y: r1.y, w: Math.max(r2.x - r1.x, 16), h: r1.height, label: lab })
                        }
                        cv.hintRects = rects
                    }
                    Connections {
                        target: cv
                        function onHintingChanged() {
                            if (cv.hinting && index === cv.hintIndex) Qt.callLater(bodyText.computeRects)
                        }
                    }

                    // the real KeyCap, drawn live — family spec, crisp at any scale
                    Repeater {
                        model: (cv.hinting && index === cv.hintIndex) ? cv.hintRects : []
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool dim: cv.hintBuf !== "" && modelData.label.indexOf(cv.hintBuf) !== 0
                            x: modelData.x
                            y: modelData.y + (modelData.h - height) / 2
                            width: modelData.w
                            height: 18
                            radius: 5
                            border.width: dim ? 0 : 1
                            border.color: Theme.hairline
                            color: dim ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData.label
                                color: parent.dim ? Theme.fg_muted : Theme.fg
                                font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                                renderType: Text.NativeRendering
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: replyFooter
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 30 + inputBox.height + 12
        color: Theme.bg

        Row {
            anchors { left: parent.left; leftMargin: 24; right: parent.right; rightMargin: 14; top: parent.top }
            height: 26; spacing: 8
            // the toggle only exists when reply-all actually adds anyone
            readonly property bool hasAudience: cv.computeRecipients(true).cc.length > 0
            Text {
                renderType: Text.NativeRendering
                anchors.verticalCenter: parent.verticalCenter
                text: "↰ " + cv.replyPrimary()
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 12
                elide: Text.ElideRight
                width: Math.min(implicitWidth, parent.width - 160)
            }
            Rectangle {
                visible: parent.hasAudience
                anchors.verticalCenter: parent.verticalCenter
                height: 18; radius: 9; width: allLbl.implicitWidth + 16
                color: cv.replyAll ? Theme.cursor : "transparent"
                border.width: 1
                border.color: cv.replyAll ? Theme.cursor : Theme.hairline
                Text {
                    id: allLbl
                    renderType: Text.NativeRendering
                    anchors.centerIn: parent
                    text: cv.replyAll ? "+" + cv.replyExtras() + " all" : "sender only"
                    color: cv.replyAll ? Theme.ink : Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                }
                TapHandler { onTapped: cv.replyAll = !cv.replyAll }
            }
        }

        // insert-mode chat field, same focus language as the chat composers
        Rectangle {
            id: inputBox
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                      leftMargin: 14; rightMargin: 14; bottomMargin: 10 }
            height: Math.min(180, replyInput.implicitHeight + 22)
            radius: Theme.radius
            readonly property bool focused: replyInput.activeFocus
            color: focused ? Theme.tintFill : Theme.surface
            border.color: focused ? (Theme.mode === "light" ? Theme.fg : "#FFFFFF") : Theme.hairline
            border.width: focused ? 1.5 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }

            Flickable {
                id: replyFlick
                anchors.fill: parent
                anchors { leftMargin: 12; rightMargin: 12; topMargin: 10; bottomMargin: 10 }
                contentHeight: replyInput.implicitHeight; clip: true
                function ensureVisible(r) {
                    if (contentY >= r.y) contentY = r.y
                    else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
                }
                TextArea {
                    id: replyInput
                    width: replyFlick.width
                    onCursorRectangleChanged: replyFlick.ensureVisible(cursorRectangle)
                    wrapMode: TextArea.Wrap
                    color: Theme.fg
                    cursorDelegate: Rectangle { width: 2; radius: 1; color: Theme.cursor; opacity: replyInput.cursorVisible ? 1 : 0 }
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 14
                    placeholderText: "Reply to " + cv.replyTargetName() + "…  (i)"
                    placeholderTextColor: Theme.fg_muted
                    background: null
                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Escape) { cv.exitInsert(); e.accepted = true; return }
                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                            if (e.modifiers & Qt.ShiftModifier) { e.accepted = false; return }
                            cv.sendReply(); e.accepted = true
                        }
                    }
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
