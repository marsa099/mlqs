import QtQuick
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

    // The REAL picker-chin keycap (rounded, hairline border) — rich text can't
    // draw that inline, so the KeyCap component is rendered to tiny cached
    // images (per label/theme, 2x for hidpi) and inlined as <img>.
    property var capCache: ({})
    Item {
        width: 0; height: 0; clip: true
        Rectangle {
            id: capProto
            property bool dim: false
            radius: 7
            border.width: dim ? 0 : 1
            border.color: Theme.hairline
            color: dim ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
            width: capText.implicitWidth + 12
            height: 20
            Text {
                id: capText
                anchors.centerIn: parent
                color: capProto.dim ? Theme.fg_muted
                     : Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                renderType: Text.NativeRendering
            }
        }
    }
    function _capKey(label, dim) { return Theme.mode + (dim ? "-d-" : "-n-") + label }
    function _ensureCaps(labels, done) {
        const missing = []
        for (const l of labels) {
            if (!capCache[_capKey(l, false)]) missing.push([l, false])
            if (!capCache[_capKey(l, true)]) missing.push([l, true])
        }
        function next() {
            if (missing.length === 0) { done(); return }
            const pair = missing.shift()
            const l = pair[0], dim = pair[1]
            capProto.dim = dim; capText.text = l
            Qt.callLater(() => {
                const w = capProto.width, h = capProto.height
                capProto.grabToImage(res => {
                    const p = Quickshell.env("XDG_RUNTIME_DIR") + "/mlqs-cap-" + cv._capKey(l, dim) + ".png"
                    if (res.saveToFile(p)) {
                        const m = Object.assign({}, cv.capCache)
                        m[cv._capKey(l, dim)] = { path: p, w: w }
                        cv.capCache = m
                    }
                    next()
                }, Qt.size(w * 2, h * 2))
            })
        }
        next()
    }
    function _badge(label, dim) {
        const c = capCache[_capKey(label, dim)]
        if (!c)
            return '<span style="color:' + Theme.fg_muted + ';font-size:12px;">&nbsp;' + label + '&nbsp;</span>&#8202;'
        return '<img src="file://' + c.path + '" width="' + c.w + '" style="vertical-align: middle">&#8202;'
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
        const at = list.currentIndex
        _ensureCaps(labels, () => {
            hintIndex = at; hintBuf = ""; hinting = true
            _renderHints()
        })
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
