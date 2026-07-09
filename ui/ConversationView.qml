import QtQuick
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

    // Picker-chin keycap language: quiet surface chip, secondary ink, w500 —
    // like the esc/enter caps, not the loud unread pill. Chips that can no
    // longer match the typed prefix lose the chip and fade to muted.
    function _badge(label, dim) {
        if (dim)
            return '<span style="color:' + Theme.fg_muted
                 + ';font-weight:500;font-size:12px;">&nbsp;' + label + '&nbsp;</span>&#8202;'
        return '<span style="background-color:' + Theme.surface2 + ';color:' + Theme.fg_secondary
             + ';font-weight:500;font-size:12px;">&nbsp;' + label + '&nbsp;</span>&#8202;'
    }
    function _renderHints() {
        let k = 0
        _hintRe.lastIndex = 0
        hintedHtml = hintBaseHtml.replace(_hintRe, tag => {
            const lab = hintLabels[k++]
            const dim = hintBuf !== "" && lab.indexOf(hintBuf) !== 0
            return _badge(lab, dim) + tag
        })
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
        hintTargets = targets; hintLabels = labels; hintBaseHtml = html
        hintIndex = list.currentIndex; hintBuf = ""; hinting = true
        _renderHints()
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
        if (hintLabels.some(l => l.indexOf(buf) === 0)) {
            hintBuf = buf
            _renderHints()
        } else cancelHints()
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
                    // mono at default leading reads cramped — the readability fix
                    lineHeight: 1.4
                    lineHeightMode: Text.ProportionalHeight
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
