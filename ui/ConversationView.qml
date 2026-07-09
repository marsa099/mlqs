import QtQuick
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
        list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
    }
    function clampY(y) {
        return Math.max(list.originY, Math.min(list.originY + list.contentHeight - list.height, y))
    }
    // j/k scroll; at a scroll edge (or when the thread fits the viewport,
    // where scrolling has nowhere to go) they flow into message-focus moves
    function scrollLine(d) {
        const maxY = list.originY + list.contentHeight - list.height
        const atEdge = d > 0 ? list.contentY >= maxY - 1 : list.contentY <= list.originY + 1
        if (atEdge) { move(d); return }
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
    function openCurrentHtml() {
        const m = Backend.messages[list.currentIndex]
        if (m && m.hasHtml) Backend.openHtml(m.id)
        else Backend.toast("no html body")
    }

    // vimium-style link hints: `f` injects [a]/[s]… labels before every link
    // and image in the FOCUSED message's rich text; typing a label opens it.
    property bool hinting: false
    property string hintBuf: ""
    property var hintTargets: []
    property var hintLabels: []
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
        let k = 0
        _hintRe.lastIndex = 0
        hintedHtml = hintBaseHtml.replace(_hintRe, tag => _reserved(hintLabels[k++]) + tag)
    }
    function startHints() {
        const m = Backend.messages[list.currentIndex]
        if (!m) return
        const html = m.bodyRich || ""
        const targets = []
        let match
        _hintRe.lastIndex = 0
        while ((match = _hintRe.exec(html)) !== null) targets.push(match[1] || match[2])
        if (targets.length === 0) { Backend.toast("no links in message"); return }
        const A = "asdfghjkl"
        let labels
        if (targets.length <= A.length) labels = A.slice(0, targets.length).split("")
        else {
            labels = []
            for (let i = 0; i < A.length && labels.length < targets.length; i++)
                for (let j = 0; j < A.length && labels.length < targets.length; j++)
                    labels.push(A[i] + A[j])
        }
        hintTargets = targets; hintLabels = labels
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
            const url = hintTargets[exact]
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
            if (Backend.messages.length > 0) Qt.callLater(cv.focusNewest)
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
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 0 }
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

            // every message is a card; focus shows as the gutter cursor bar,
            // not as a lone card that reads like an inconsistency
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                radius: Theme.radius
                color: Theme.surface1
                border.color: Theme.hairline
                border.width: 1
            }
            Rectangle {
                visible: index === list.currentIndex && Backend.messages.length > 1
                anchors.left: parent.left; anchors.leftMargin: 10
                anchors.top: parent.top; anchors.topMargin: 14
                width: 3; height: 24; radius: 2
                color: Theme.cursor
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
                            const lab = cv.hintLabels[k]
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

    Text {
        renderType: Text.NativeRendering
        anchors.centerIn: parent
        visible: list.count === 0
        text: "loading…"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13
    }
}
