import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import "."
import QsLib

Rectangle {
    id: cv
    color: Theme.bg
    radius: Theme.radiusCard

    function focusedMsg() {
        const i = list.currentIndex
        if (i >= 0 && i < Backend.messages.length) return Backend.messages[i]
        return Backend.messages.length > 0 ? Backend.messages[Backend.messages.length - 1] : null
    }

    // the focused message when it carries an invite, else null
    function inviteMsg() {
        const i = list.currentIndex
        const m = (i >= 0 && i < Backend.messages.length) ? Backend.messages[i] : null
        return (m && m.hasInvite) ? m : null
    }

    // vim scrolloff, shared by cursor motions and read-mode hops
    readonly property real scrollMargin: Math.min(120, list.height * 0.25)

    function move(d) {
        if (list.count === 0) return
        cancelHints()
        const ni = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
        // already at the edge: repositioning would snap a long message back
        // to its own top — the reading loop bug
        if (ni === list.currentIndex) return
        list.currentIndex = ni
        // scroll only when the target's start is off-screen — a focus move
        // between visible messages must not shift the view
        const it = list.itemAtIndex(list.currentIndex)
        if (!it || it.y < list.contentY - 2 || it.y > list.contentY + list.height - 40) {
            list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
            list.contentY = clampY(list.contentY - scrollMargin)
        }
    }
    function clampY(y) {
        // list margins sit OUTSIDE the content: the mouse can flick into them,
        // so keyboard scrolling must clamp to the same padded bounds
        return Math.max(list.originY - list.topMargin,
               Math.min(list.originY + list.contentHeight - list.height + list.bottomMargin, y))
    }
    // picker-grain j/k: move to the next/prev message as soon as the current
    // one's relevant edge is visible; scroll within it while it isn't. Long
    // messages read through, short ones navigate row-to-row like a picker.
    function scrollLine(d) {
        const it = list.itemAtIndex(list.currentIndex)
        if (!it) { move(d); return }
        // j/k hand focus to the adjacent message but keep the reading glide —
        // no view jumps (those belong to ⇧j/⇧k). Fully-visible targets get a
        // pure focus hop so short messages keep the picker feel.
        if (d > 0) {
            const bottomVisible = it.y + it.height <= list.contentY + list.height - scrollMargin + 2
            if (bottomVisible && list.currentIndex < list.count - 1) {
                cancelHints()
                list.currentIndex = list.currentIndex + 1
                const t = list.itemAtIndex(list.currentIndex)
                if (t && t.y >= list.contentY && t.y + t.height <= list.contentY + list.height) return
            }
        } else {
            const topVisible = it.y >= list.contentY + scrollMargin - 2
            if (topVisible && list.currentIndex > 0) {
                cancelHints()
                list.currentIndex = list.currentIndex - 1
                const t = list.itemAtIndex(list.currentIndex)
                if (t && t.y >= list.contentY && t.y + t.height <= list.contentY + list.height) return
            }
        }
        list.contentY = clampY(list.contentY + d * 90)
    }
    function scroll(d) { list.contentY = clampY(list.contentY + d * list.height / 2) }
    function toTop() { list.contentY = list.originY - list.topMargin; list.currentIndex = 0 }
    function toEnd() { list.contentY = clampY(list.originY + list.contentHeight); list.currentIndex = list.count - 1 }
    // newest message focused, scrolled to its TOP (not its end — a long
    // newsletter must open at the start, not the footer)
    function focusNewest() {
        list.currentIndex = list.count - 1
        list.positionViewAtIndex(list.currentIndex, ListView.Beginning)
    }
    signal exitInsert()
    signal mailtoRequested(string addr)
    signal hideRequested()
    function openLink(link) {
        if (link.indexOf("mailto:") === 0) {
            mailtoRequested(decodeURIComponent(link.slice(7).split("?")[0]))
            return
        }
        Qt.openUrlExternally(link)
        // opening a link sends you to the browser — hide the mail window
        // (warm, like q) so it's out of the way behind it
        hideRequested()
    }
    readonly property bool replyHasFocus: replyInput.activeFocus

    // inline reply: target message (R picks one; default newest) + reply-all
    property string replyTargetId: ""
    property bool replyAll: true
    readonly property string myEmail: {
        const w = Backend.workspaces.find(x => x.id === Backend.currentAccount)
        return w && w.email ? w.email.toLowerCase() : ""
    }
    function _lastReal() {
        for (let i = Backend.messages.length - 1; i >= 0; i--)
            if (!Backend.messages[i].local) return Backend.messages[i]
        return null
    }
    function targetMsg() {
        const hit = Backend.messages.find(m => m.id === cv.replyTargetId)
        return (hit && !hit.local) ? hit : _lastReal()
    }
    function replyTargetName() {
        const t = targetMsg()
        if (!t || !t.from) return ""
        return t.from.name || t.from.email || ""
    }
    function focusReply() { replyInput.forceActiveFocus() }
    function replyToFocused() {
        const m = Backend.messages[list.currentIndex]
        if (!m || m.local) return
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
        // Reply-To wins over From (RFC 5322): GitHub-style reply+token@
        // addresses live there, and the From is often a no-reply that bounces
        const sender = (t.replyTo && t.replyTo.length ? t.replyTo
                        : (t.from && t.from.email ? [t.from] : []))
            .map(a => a.email).filter(e => e && e.toLowerCase() !== cv.myEmail)
        let to = []
        if (sender.length) to = [...new Set(sender)]
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
        const pool = t ? [t.from].concat(t.replyTo || [], t.to || [], t.cc || []) : []
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
        Backend.appendLocalMessage({ subject: subj, body: text })
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
    property var hintKinds: []
    property var hintInners: []
    property var hintImgTargets: []
    property var _hintRawSkip: []

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
        let raw = 0, kept = 0
        _hintRe.lastIndex = 0
        hintedHtml = hintBaseHtml.replace(_hintRe, tag => {
            if (_hintRawSkip[raw++]) return tag
            const k = kept++
            if ((hintKinds[k] || "link") !== "link") return tag
            return _reserved(hintLabels[hintAttCount + k]) + tag
        })
    }
    property int _hintResumePos: -1
    function startHints() {
        _hintResumePos = cursorMode ? selC : -1
        const m = Backend.messages[list.currentIndex]
        if (!m) return
        const atts = (m.attachments || []).filter(a => !a.shownInline)
        const html = m.bodyRich || ""
        const urls = []
        const kinds = []
        let match
        _hintRe.lastIndex = 0
        const inners = []
        const imgTargets = []
        const rawSkip = []
        let imgOrd = 0
        while ((match = _hintRe.exec(html)) !== null) {
            if (match[2]) {
                // tiny icons: a view-image cap is noise — the wrapping link
                // (if any) still gets its own cap
                const wm = /width="?(\d+)/i.exec(match[0])
                if (wm && parseInt(wm[1]) < 48) { rawSkip.push(true); imgOrd++; continue }
                rawSkip.push(false)
                urls.push(match[2]); kinds.push("img"); inners.push(""); imgTargets.push(imgOrd)
                imgOrd++
                continue
            }
            const rest = html.slice(_hintRe.lastIndex, _hintRe.lastIndex + 2000)
            const close = rest.search(/<\/a>/i)
            const inner = close >= 0 ? rest.slice(0, close) : rest
            const wrapsImg = /^\s*(?:<[^>]+>\s*)*<img/i.test(rest)
            if (!wrapsImg) {
                // dropped-image leftovers render as bare underscores — an
                // anchor with no visible text is not a hintable target
                const txt = inner.replace(/<[^>]+>/g, "")
                    .replace(/&nbsp;/g, " ").replace(/&#\d+;/g, "").trim()
                if (txt.length < 2) { rawSkip.push(true); continue }
                rawSkip.push(false)
                urls.push(match[1]); kinds.push("link"); inners.push(""); imgTargets.push(-1)
                continue
            }
            rawSkip.push(false)
            urls.push(match[1]); kinds.push("imglink"); imgTargets.push(imgOrd)
            const segs = inner
                .replace(/<[^>]+>/g, "\n").split("\n").map(t => t.trim()).filter(t => t.length)
            inners.push(segs.length ? segs[segs.length - 1] : "")
        }
        let total = atts.length + urls.length
        if (total === 0) { Backend.toast("no links in message"); return }
        if (total > 81) {   // label alphabet is 9² — drop the tail
            const room = Math.max(0, 81 - atts.length)
            urls.length = room; kinds.length = room
            inners.length = room; imgTargets.length = room
            total = atts.length + urls.length
        }
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
        hintTargets = urls; hintLabels = labels; hintKinds = kinds; hintInners = inners
        hintImgTargets = imgTargets
        _hintRawSkip = rawSkip
        hintBaseHtml = html.replace(/\u200B/g, "")
        hintRects = []
        hintIndex = list.currentIndex; hintBuf = ""
        _renderHints()
        hinting = true
    }
    function cancelHints() { hinting = false; hintBuf = ""; hintIndex = -1 }
    onHintingChanged: {
        if (!hinting) Qt.callLater(function() {
            if (cv.cursorMode) {
                cv._buildLineRects()
                if (cv._hintResumePos >= 0) cv._setCursor(cv._hintResumePos, false)
                cv._hintResumePos = -1
            } else if (Backend.openConvId !== "" && Backend.messages.length === 1
                    && !cv.hinting && !cv.yanking)
                cv.cursorEnter(true)
        })
    }
    // inline images go to the family viewer (imv via media-viewer.sh),
    // links to the browser — same split as the chat clients
    function openTarget(url) {
        if (url.indexOf("file://") === 0) {
            const viewer = Quickshell.env("SLK_MEDIA_VIEWER")
                        || (Quickshell.env("HOME") + "/.config/endcord/media-viewer.sh")
            Quickshell.execDetached([viewer, url.slice(7), "img"])
            return
        }
        openLink(url)
    }
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
            openTarget(url)
            return
        }
        if (hintLabels.some(l => l.indexOf(buf) === 0)) hintBuf = buf
        else cancelHints()
    }

    // ── in-message cursor mode: a vim cursor inside the focused message.
    // Single-message conversations enter it on open; threads enter via ↵ on
    // the focused message. v anchors a visual selection from the cursor.
    // Doc positions live on the delegate's TextEdit twin (geomEdit); the
    // delegates rebuild on every Backend.messages replacement, so the mode
    // force-exits on messagesChanged and every motion null-guards the twin.
    property bool cursorMode: false
    property bool showCursor: false
    property int  cursorIndex: -1
    property bool anchored: false
    property bool linewise: false
    property int  selA: -1
    property int  selC: -1
    property real vColX: 0
    property var  lineRects: []
    property var  imgSelRects: []
    property var  copyFlashRect: null
    // the picked yank badge morphs into the copy glyph (slqs icon-swap)
    property var pickFlash: null
    property int pickFlashIndex: -1
    Timer {
        id: pickFlashClear
        interval: 1200
        onTriggered: {
            cv.pickFlash = null; cv.pickFlashIndex = -1
            if (cv.yanking) cv.cancelYank()   // teardown after the morph, not during
        }
    }

    // y-mode: labels over significant tokens; picking one copies it
    property bool yanking: false
    property string yankBuf: ""
    property var yankTokens: []
    property var yankLabels: []
    property var yankRects: []
    property string yankHtml: ""
    property int yankIndex: -1
    property bool _yankFromCursor: false
    property int _yankResumePos: -1
    property bool _yankResumeShow: false
    property string _yankPlainDoc: ""

    readonly property int curLine: (cursorMode && selC >= 0) ? _lineOf(selC) : 0

    function _lineOf(pos) {
        const g = _vGeom(); if (!g || !lineRects.length) return 0
        const y = g.positionToRectangle(pos).y
        for (let i = 0; i < lineRects.length; i++)
            if (y < lineRects[i].y + lineRects[i].h - 1) return i
        return lineRects.length - 1
    }

    function _vGeom() {
        if (cursorIndex < 0) return null
        const it = list.itemAtIndex(cursorIndex)
        return it ? it.geomEdit : null
    }
    function cursorEnter(quiet) {
        cancelHints()
        const it = list.itemAtIndex(list.currentIndex)
        const g = it ? it.geomEdit : null
        if (!g || g.length === 0 || !/\S/.test(g.getText(0, g.length))) {
            if (!quiet) Backend.toast("no text to select")
            return false
        }
        cursorIndex = list.currentIndex
        anchored = false
        // start at the first visible char — a scrolled newsletter must not snap to its top
        const gy = g.mapToItem(list.contentItem, 0, 0).y
        const p = g.positionAt(0, Math.max(0, list.contentY - gy) + 4)
        selA = p; selC = p
        vColX = g.positionToRectangle(p).x
        showCursor = false
        cursorMode = true
        _applySel()
        _buildLineRects()
        return true
    }
    function _cursorOff() {
        const g = _vGeom()
        if (g) g.deselect()
        cursorMode = false
        showCursor = false
        anchored = false; linewise = false
        cursorIndex = -1; selA = -1; selC = -1
        lineRects = []; imgSelRects = []
    }
    function cursorExit() {
        _cursorOff()
        cancelYank()
    }
    // v: anchor a selection at the cursor / drop it again (vim visual toggle);
    // from V-line it narrows to charwise, matching vim
    function visualToggle() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        showCursor = true
        if (anchored && !linewise) { anchored = false; g.deselect() }
        else if (anchored && linewise) { linewise = false; _applySel() }
        else { selA = selC; anchored = true; linewise = false; _applySel() }
    }
    function dropAnchor() {
        const g = _vGeom()
        anchored = false; linewise = false
        if (g) g.deselect()
        imgSelRects = []
    }
    // V: linewise selection over display lines (what j/k and the gutter count)
    function lineToggle() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        showCursor = true
        if (anchored && linewise) { anchored = false; linewise = false; g.deselect() }
        else {
            if (!anchored) selA = selC
            anchored = true; linewise = true
            _applySel()
        }
    }
    function _applySel() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        if (anchored && linewise) {
            if (!lineRects.length) _buildLineRects()
            const la = _lineOf(selA), lc = _lineOf(selC)
            const lo = Math.min(la, lc), hi = Math.max(la, lc)
            const st = g.positionAt(0, lineRects[lo].y + lineRects[lo].h / 2)
            const en = g.positionAt(1e6, lineRects[hi].y + lineRects[hi].h / 2)
            g.select(st, Math.min(g.length, en))
        } else if (anchored) {
            // inclusive vim selection: the cursor char is always selected
            if (selC >= selA) g.select(selA, Math.min(g.length, selC + 1))
            else g.select(Math.min(g.length, selA + 1), selC)
        } else g.deselect()
        imgSelRects = anchored ? _imageRects(g) : []
        _ensureCursorVisible()
    }
    function _setCursor(p, keepCol) {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        let np = Math.max(0, Math.min(g.length - 1, p))
        // vim invariant: the cursor never rests on a line separator — except
        // on an empty line, where the separator IS the line
        const doc = g.getText(0, g.length)
        const sep = ch => ch === "\u2028" || ch === "\u2029" || ch === "\n"
        while (np > 0 && sep(doc[np])) {
            const r = g.positionToRectangle(np)
            if (g.positionAt(0, r.y + r.height / 2) === np) break   // empty line
            np--
        }
        selC = np
        if (!keepCol) vColX = g.positionToRectangle(selC).x
        _applySel()
    }
    function vChar(n) {
        if (!showCursor) { showCursor = true; _setCursor(selC, false); return }
        _setCursor(selC + n, false)
    }
    function vLine(n) {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        if (!lineRects.length) _buildLineRects()
        if (!lineRects.length) return
        const li = Math.max(0, Math.min(lineRects.length - 1, curLine + n))
        const lr = lineRects[li]
        _setCursor(g.positionAt(vColX, lr.y + lr.h / 2), true)
    }
    function _cls(ch) {
        if (!ch || /\s/.test(ch)) return 0
        return /[A-Za-z0-9_À-ɏ]/.test(ch) ? 1 : 2
    }
    function vWord(kind, n) {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        showCursor = true
        const doc = g.getText(0, g.length)
        if (!doc.length) return
        // uppercase = vim WORD: whitespace-delimited, punctuation glues on
        const big = kind === kind.toUpperCase()
        const cls = big ? (ch => _cls(ch) === 0 ? 0 : 1) : _cls
        const k = kind.toLowerCase()
        const last = doc.length - 1
        let p = selC
        for (let i = 0; i < n; i++) {
            if (k === "w") {
                const c = cls(doc[p])
                if (c !== 0) while (p < last && cls(doc[p]) === c) p++
                while (p < last && cls(doc[p]) === 0) p++
            } else if (k === "b") {
                if (p > 0) p--
                while (p > 0 && cls(doc[p]) === 0) p--
                const c = cls(doc[p])
                if (c !== 0) while (p > 0 && cls(doc[p - 1]) === c) p--
            } else {
                if (p < last) p++
                while (p < last && cls(doc[p]) === 0) p++
                const c = cls(doc[p])
                if (c !== 0) while (p < last && cls(doc[p + 1]) === c) p++
            }
        }
        _setCursor(p, false)
    }
    function vLineStart() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        showCursor = true
        const r = g.positionToRectangle(selC)
        _setCursor(g.positionAt(0, r.y + r.height / 2), false)
    }
    // ^: first non-blank of the display line (vim semantics)
    function vLineFirst() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        showCursor = true
        const r = g.positionToRectangle(selC)
        const midY = r.y + r.height / 2
        let p = g.positionAt(0, midY)
        const le = Math.max(p, g.positionAt(1e6, midY) - 1)
        const doc = g.getText(0, g.length)
        while (p < le && /\s/.test(doc[p])) p++
        _setCursor(p, false)
    }
    function vLineEnd() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        showCursor = true
        const r = g.positionToRectangle(selC)
        const midY = r.y + r.height / 2
        const ls = g.positionAt(0, midY)
        _setCursor(Math.max(ls, g.positionAt(1e6, midY) - 1), false)
    }
    function vDocStart() { _setCursor(0, false) }
    function vDocEnd() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        _setCursor(g.length - 1, false)
    }
    function vSwap() {
        const a = selA
        selA = selC
        _setCursor(a, false)
    }
    function _yankDone(g) {
        anchored = false; linewise = false
        g.deselect(); imgSelRects = []
    }
    function _allImgSrcs(g) {
        const srcs = []
        const re = /<img\s[^>]*src="([^"]+)"/gi
        let m
        while ((m = re.exec(g.text)) !== null) srcs.push(m[1])
        return srcs
    }
    function vYank() {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        // bar-only state: the cursor hasn't been placed deliberately, so y
        // means yank-hints — even if the hidden cursor sits on an image cell
        if (!anchored && !showCursor) { startYank(); return }
        if (anchored) {
            const t = g.selectedText
                .replace(/[\u2028\u2029]/g, "\n")
                .replace(/[\uFFFC\u200B]/g, "")
            const hasText = /\S/.test(t)
            const doc0 = g.getText(0, g.length)
            const span0 = doc0.slice(g.selectionStart, g.selectionEnd)
            if (hasText && span0.indexOf("\uFFFC") >= 0) {
                // mixed text + images: rich html with data-uri images
                const srcs = _allImgSrcs(g)
                let k = (doc0.slice(0, g.selectionStart).match(/\uFFFC/g) || []).length
                let html = ""
                for (const ch of span0) {
                    if (ch === "\uFFFC") { if (srcs[k]) html += '<img src="' + srcs[k] + '">'; k++ }
                    else if (ch === "\u2028" || ch === "\u2029" || ch === "\n") html += "<br>"
                    else if (ch === "\u200B") continue
                    else if (ch === "&") html += "&amp;"
                    else if (ch === "<") html += "&lt;"
                    else if (ch === ">") html += "&gt;"
                    else html += ch
                }
                Backend.copyRichToClipboard(html)
                _yankDone(g)
                return
            }
            if (hasText) {
                Backend.copyToClipboard(t)
                _yankDone(g)
                return
            }
        }
        // no text in range: an inline image is one object char — resolve the
        // Nth object in the doc to the Nth <img> in the HTML and copy the file
        const doc = g.getText(0, g.length)
        const start = anchored ? g.selectionStart : selC
        const end = anchored ? g.selectionEnd : Math.min(g.length, selC + 1)
        const oi = doc.slice(start, end).indexOf("\uFFFC")
        if (oi < 0) {
            if (anchored) { Backend.toast("nothing to copy"); return }
            startYank(); return
        }
        const nth = (doc.slice(0, start + oi).match(/\uFFFC/g) || []).length
        const srcs = []
        const re = /<img\s[^>]*src="([^"]+)"/gi
        let m
        while ((m = re.exec(g.text)) !== null) srcs.push(m[1])
        if (nth >= srcs.length) { Backend.toast("nothing to copy"); return }
        const fr = g.positionToRectangle(start + oi)
        copyFlashRect = { x: fr.x, y: fr.y, h: fr.height,
                          w: _objWidth(g, start + oi, nth, _imgWidths(g)) }
        Backend.copyImageToClipboard(srcs[nth])
        anchored = false; linewise = false
        g.deselect(); imgSelRects = []
    }
    function vHalfPage(d) {
        const g = _vGeom(); if (!g) { cursorExit(); return }
        if (!lineRects.length) _buildLineRects()
        if (!lineRects.length) return
        const targetY = lineRects[curLine].y + d * list.height / 2
        let li = 0
        for (let i = 0; i < lineRects.length; i++)
            if (lineRects[i].y <= targetY) li = i
        // a line taller than half the viewport (hero image) contains the
        // target itself — force at least one line of progress or ⌃d sticks
        if (li === curLine)
            li = Math.max(0, Math.min(lineRects.length - 1, curLine + (d > 0 ? 1 : -1)))
        _setCursor(g.positionAt(vColX, lineRects[li].y + lineRects[li].h / 2), true)
    }
    // view scroll, cursor stays put — vim ctrl-e/y
    function vScroll(d) {
        const lh = lineRects.length ? lineRects[curLine].h : 20
        list.contentY = clampY(list.contentY + d * lh)
    }
    function _ensureCursorVisible() {
        const g = _vGeom(); if (!g) return
        const r = g.positionToRectangle(selC)
        const y = g.mapToItem(list.contentItem, 0, r.y).y
        const m = scrollMargin
        if (y < list.contentY + m) list.contentY = clampY(y - m)
        else if (y + r.height > list.contentY + list.height - m)
            list.contentY = clampY(y + r.height - list.height + m)
    }
    function _buildLineRects() {
        const g = _vGeom()
        if (!g) { lineRects = []; return }
        const rs = []
        let p = 0, guard = 0
        while (p < g.length && guard++ < 4000) {
            const r = g.positionToRectangle(p)
            rs.push({ y: r.y, h: r.height })
            const np = g.positionAt(0, r.y + r.height + 2)
            if (np <= p) break
            p = np
        }
        lineRects = rs
    }
    // rendered <img> widths in document order — the geometry fallback when
    // "position after the image" wraps to the next display line
    function _imgWidths(g) {
        const ws = []
        const re = /<img\s[^>]*?>/gi
        let m
        while ((m = re.exec(g.text)) !== null) {
            const wm = /width="?(\d+)/i.exec(m[0])
            ws.push(wm ? parseInt(wm[1]) : 0)
        }
        return ws
    }
    function _objWidth(g, p, k, widths) {
        const r1 = g.positionToRectangle(p), r2 = g.positionToRectangle(p + 1)
        if (r2.y === r1.y && r2.x > r1.x) return r2.x - r1.x
        const w = widths[k] || 0
        return Math.max(8, Math.min(w > 0 ? w : g.width - r1.x, g.width - r1.x))
    }
    function objWidthAt(pos) {
        const g = _vGeom(); if (!g) return 8
        const doc = g.getText(0, g.length)
        if (doc[pos] !== "￼") return 8
        const k = (doc.slice(0, pos).match(/￼/g) || []).length
        return _objWidth(g, pos, k, _imgWidths(g))
    }
    function _imageRects(g) {
        const doc = g.getText(0, g.length)
        const s = g.selectionStart, e = g.selectionEnd
        const widths = _imgWidths(g)
        const rects = []
        let k = -1
        for (let p = doc.indexOf("￼"); p >= 0; p = doc.indexOf("￼", p + 1)) {
            k++
            if (p < s) continue
            if (p >= e) break
            const r1 = g.positionToRectangle(p)
            rects.push({ x: r1.x, y: r1.y, h: r1.height, w: _objWidth(g, p, k, widths) })
        }
        return rects
    }

    // y with nothing selected: label the message's significant tokens —
    // codes, URLs, emails, dashed IDs, amounts, links — pick one to copy it.
    // Same mechanism as the f hints: reserved inline gaps in the HTML, caps
    // drawn in the reflowed space. Cursor state is stashed and restored — the
    // original document comes back byte-identical, so positions stay valid.
    function _htmlTextIndexOf(html, needle, from) {
        let i = html.indexOf(needle, from)
        while (i >= 0) {
            const lt = html.lastIndexOf("<", i), gt = html.lastIndexOf(">", i)
            if (lt <= gt) return i
            i = html.indexOf(needle, i + 1)
        }
        return -1
    }
    function startYank() {
        cancelHints()
        const host = list.itemAtIndex(list.currentIndex)
        const g = host ? host.geomEdit : null
        if (!g || g.length === 0) { Backend.toast("no text to yank"); return }
        const doc = g.getText(0, g.length)
        const m0 = Backend.messages[list.currentIndex]
        const base = ((m0 && m0.bodyRich) || "").replace(/\u200B/g, "")
        if (!base.length) { Backend.toast("no text to yank"); return }
        const pats = [
            /https?:\/\/[^\s<>"')\]]+/g,
            /\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b/g,
            /\b[A-Z0-9]{2,}(?:-[A-Z0-9]{2,})+\b/g,
            /[$€£]\s?\d[\d,.]*/g,
            /\b\d[\d,.]*\s?(?:USD|EUR|SEK|kr)\b/g,
            /\b\d{4,}\b/g,
        ]
        const dec = t => t.replace(/<[^>]+>/g, "")
            .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
            .replace(/&quot;/g, '"').replace(/&nbsp;/g, " ")
            .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(n)).trim()
        let found = []
        // rendered links: label lands at the <a> tag, copies the href
        const aRe = /<a\s[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi
        let am, docFrom = 0
        while ((am = aRe.exec(base)) !== null) {
            const label = dec(am[2])
            if (!label.length) continue
            const at = doc.indexOf(label, docFrom)
            if (at < 0) continue
            docFrom = at + label.length
            found.push({ s: at, e: at + label.length, copy: am[1],
                         htmlAt: am.index, htmlEnd: am.index + am[0].length })
        }
        for (const re of pats) {
            let m
            while ((m = re.exec(doc)) !== null)
                found.push({ s: m.index, e: m.index + m[0].length, copy: m[0] })
        }
        found.sort((a, b) => a.s - b.s || b.e - a.e)
        const dedup = []
        let lastEnd = -1
        for (const t of found) {
            if (t.s < lastEnd) continue
            dedup.push(t); lastEnd = t.e
        }
        // map every token to an ascending HTML insertion offset; unfindable
        // ones (entity-mangled text) drop out
        const placed = []
        let htmlFrom = 0, lastAt = -1
        for (const t of dedup) {
            let at
            if (t.htmlAt !== undefined) {
                at = t.htmlAt
                htmlFrom = Math.max(htmlFrom, t.htmlEnd)
            } else {
                at = _htmlTextIndexOf(base, t.copy, htmlFrom)
                if (at < 0) continue
                htmlFrom = at + t.copy.length
            }
            if (at <= lastAt) continue
            lastAt = at
            placed.push({ copy: t.copy, at: at })
        }
        // every rendered image is copyable too — overlay caps, no reflow
        const iRe = /<img\s[^>]*?>/gi
        let im, iOrd = 0
        while ((im = iRe.exec(base)) !== null) {
            const srcm = /src="([^"]+)"/i.exec(im[0])
            const wm = /width="?(\d+)/i.exec(im[0])
            const tiny = wm && parseInt(wm[1]) < 48
            if (srcm && !tiny) placed.push({ copy: srcm[1], at: im.index, img: true, ord: iOrd })
            iOrd++
        }
        placed.sort((a, b) => a.at - b.at)
        if (!placed.length) { Backend.toast("no codes/links found — yy copies all"); return }
        if (placed.length > 81) placed.length = 81   // label alphabet is 9²
        const A = "asdfghjkl"
        let labels
        if (placed.length <= A.length) labels = A.slice(0, placed.length).split("")
        else {
            labels = []
            for (let i = 0; i < A.length && labels.length < placed.length; i++)
                for (let j = 0; j < A.length && labels.length < placed.length; j++)
                    labels.push(A[i] + A[j])
        }
        let out = "", prev = 0
        for (let i = 0; i < placed.length; i++) {
            out += base.slice(prev, placed[i].at)
            if (!placed[i].img) out += _reserved(labels[i])
            prev = placed[i].at
        }
        out += base.slice(prev)
        // stash cursor position; cursor mode stays alive so the gutter
        // persists (the gap-injected doc flows into geom, same as f-hints)
        _yankFromCursor = cursorMode
        _yankResumePos = selC
        _yankResumeShow = showCursor
        _yankPlainDoc = doc
        yankTokens = placed
        yankLabels = labels
        yankRects = []
        yankIndex = list.currentIndex
        yankHtml = out
        yankBuf = ""
        yanking = true
    }
    function cancelYank() {
        const resumePos = _yankFromCursor ? _yankResumePos : -1
        const resumeShow = _yankResumeShow
        yanking = false; yankBuf = ""; yankTokens = []; yankLabels = []; yankRects = []
        yankHtml = ""; yankIndex = -1
        _yankFromCursor = false; _yankPlainDoc = ""
        if (resumePos >= 0) Qt.callLater(function() {
            if (Backend.openConvId === "") return
            if (!cv.cursorMode && !cv.cursorEnter(true)) return
            cv._buildLineRects()
            cv.showCursor = resumeShow
            cv._setCursor(resumePos, false)
        })
    }
    function yankKey(ch) {
        if (pickFlash) return   // pick pending — animation owns the overlay
        const buf = yankBuf + ch
        const exact = yankLabels.indexOf(buf)
        if (exact >= 0) {
            const t = yankTokens[exact]
            const host = list.itemAtIndex(list.currentIndex)
            const pr = yankRects.find(r => r.label === buf)
            if (pr) {
                pickFlash = { x: pr.x, y: pr.y, w: pr.w, h: pr.h }
                pickFlashIndex = list.currentIndex
                pickFlashClear.restart()
            }
            yankBuf = buf   // full match dims every other cap during the hold
            if (t.img) {
                // the overlay doc is still live — gaps are text-only, so image
                // ordinals (and their rects) are valid right now
                const g = host ? host.geomEdit : null
                if (g) {
                    const doc = g.getText(0, g.length)
                    let ip = -1, k = -1
                    for (ip = doc.indexOf("\uFFFC"); ip >= 0 && ++k < t.ord; ip = doc.indexOf("\uFFFC", ip + 1)) {}
                    if (ip >= 0) {
                        const fr = g.positionToRectangle(ip)
                        copyFlashRect = { x: fr.x, y: fr.y, h: fr.height,
                                          w: _objWidth(g, ip, t.ord, _imgWidths(g)) }
                    }
                }
                Backend.copyImageToClipboard(t.copy)
            } else Backend.copyToClipboard(t.copy)
            return
        }
        if (yankLabels.some(l => l.indexOf(buf) === 0)) yankBuf = buf
        else cancelYank()
    }
    function yankWholeMessage() {
        let doc = _yankPlainDoc
        if (!doc.length) {
            const host = list.itemAtIndex(list.currentIndex)
            const g = host ? host.geomEdit : null
            if (!g) { cancelYank(); return }
            doc = g.getText(0, g.length)
        }
        cancelYank()
        const t = doc
            .replace(/[\u2028\u2029]/g, "\n")
            .replace(/[\uFFFC\u200B]/g, "")
        Backend.copyToClipboard(t.trim())
    }
    Connections {
        target: Backend
        function onMessagesChanged() {
            // every messages replacement rebuilds the delegates — a live
            // selection would point at a destroyed TextEdit
            if (cv.cursorMode) cv.cursorExit()
            if (Backend.messages.length === 0) return
            const t = cv._lastReal()
            if (!t) return
            cv.replyTargetId = t.id
            // default to reply-all when the newest message had an audience
            cv.replyAll = ((t.to || []).length + (t.cc || []).length) > 1
            Qt.callLater(function() {
                cv.focusNewest()
                if (Backend.openConvId !== "" && Backend.messages.length === 1)
                    Qt.callLater(function() {
                        if (!cv.cursorMode && !cv.cursorEnter(true))
                            Qt.callLater(function() { if (!cv.cursorMode) cv.cursorEnter(true) })
                    })
            })
        }
        function onOpenConvIdChanged() { if (cv.cursorMode) cv.cursorExit() }
    }
    property int _resumeIdx: -1
    property int _resumePos: -1
    onReplyHasFocusChanged: {
        if (replyHasFocus) {
            if (cursorMode) { _resumeIdx = cursorIndex; _resumePos = selC; cursorExit() }
            else { _resumeIdx = -1; _resumePos = -1 }
        } else Qt.callLater(function() {
            if (Backend.openConvId === "" || cv.cursorMode) return
            if (cv.cursorEnter(true) && cv._resumeIdx === cv.cursorIndex && cv._resumePos >= 0) {
                cv.showCursor = true
                cv._setCursor(cv._resumePos, false)
            }
        })
    }

    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        // transparent so the card's rounded top corners stay rounded
        height: 52; color: "transparent"
        Text {
            anchors.left: parent.left; anchors.leftMargin: 14
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: Backend.openConvSubject + (cv.hinting ? "   󰌒 " + (cv.hintBuf || "type label…") : "")
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 14; font.weight: 600
            elide: Text.ElideRight
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairlineSoft }
    }

    ListView {
        id: list
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: replyFooter.top; margins: 0 }
        model: Backend.messages
        clip: true
        spacing: 10
        topMargin: 20
        bottomMargin: 20
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 60

        ScrollFeel { flick: list }

        delegate: Rectangle {
            id: dl
            required property var modelData
            required property int index
            width: list.width
            height: content.height + (multi ? 100 : 24)
            color: "transparent"
            readonly property bool inVisual: cv.cursorMode && index === cv.cursorIndex
            property alias geomEdit: geom

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
                // every message keeps a soft outline so thread boundaries read
                // in long conversations; focus still gets the full accent
                border.color: parent.focusedMsg ? Theme.hairline
                             : multi ? Theme.hairlineSoft : "transparent"
            }
            // copy feedback, slqs grammar: flash in sync with the bar morph
            Rectangle {
                id: copyFlash
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                radius: Theme.radius
                color: Qt.darker(Theme.selection, 1.03)
                property bool showCopy: false
                opacity: showCopy ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                Connections {
                    target: Backend
                    function onCopyPulseChanged() {
                        if (dl.index === list.currentIndex && !cv.copyFlashRect && !cv.pickFlash) {
                            copyFlash.showCopy = true; copyRevert.restart()
                        }
                    }
                }
                Timer { id: copyRevert; interval: 1500; onTriggered: copyFlash.showCopy = false }
            }

            Column {
                id: content
                anchors.top: parent.top; anchors.topMargin: dl.multi ? 50 : 12
                // constant gutter reserve — line numbers live here; a static
                // margin keeps messages aligned and mode changes slide-free
                anchors.left: parent.left; anchors.leftMargin: 60
                // readable column: don't let body lines run the full window width
                width: Math.min(parent.width - 48, 820)
                spacing: 12

                Row {
                    spacing: 10
                    Text {
                        text: modelData.from ? (modelData.from.name || modelData.from.email) : "?"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 13; font.weight: 600
                    }
                    Text {
                        text: modelData.from && modelData.from.name ? "<" + modelData.from.email + ">" : ""
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: Backend.fmtDate(modelData.date)
                        color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    // optimistic-echo lifecycle: pulsing dot while in flight,
                    // red marker if the daemon reports a send failure
                    Row {
                        visible: modelData.sending === true
                        spacing: 5
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            width: 7; height: 7; radius: 4; color: Theme.cursor
                            anchors.verticalCenter: parent.verticalCenter
                            SequentialAnimation on opacity {
                                running: modelData.sending === true; loops: Animation.Infinite
                                NumberAnimation { from: 1; to: 0.25; duration: 550 }
                                NumberAnimation { from: 0.25; to: 1; duration: 550 }
                            }
                        }
                        Text {
                            text: "sending…"
                            color: Theme.fg_muted
                            font.family: Theme.fontFamily; font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Text {
                        visible: modelData.failed === true
                        text: "failed to send"
                        color: Theme.red
                        font.family: Theme.fontFamily; font.pixelSize: 11
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
                            anchors.centerIn: parent
                            text: "new"
                            color: Theme.ink
                            font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: 600
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: text !== ""
                    text: cv.recipientLine(modelData)
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                // calendar invite: RSVP straight from the mail (y / m / x on
                // the focused message do the same via keys)
                Row {
                    visible: modelData.hasInvite === true
                    spacing: 8
                    Icon {
                        width: 14; height: 14
                        anchors.verticalCenter: parent.verticalCenter
                        name: "calendar-days"
                        color: Theme.fg_muted
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Invitation"
                        color: Theme.fg_secondary
                        font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                    }
                    Repeater {
                        model: [
                            { label: "accept", status: "accepted", cap: "y" },
                            { label: "maybe", status: "tentative", cap: "m" },
                            { label: "decline", status: "declined", cap: "n" }
                        ]
                        Rectangle {
                            required property var modelData
                            readonly property string msgId: parent.parent.parent.modelData.id
                            height: 22; radius: 11
                            width: rsvpLbl.implicitWidth + 22
                            anchors.verticalCenter: parent.verticalCenter
                            color: rsvpHov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
                                 : Theme.mode === "light" ? Theme.bg : Theme.surface2
                            border.width: 1; border.color: Theme.hairline
                            HoverHandler { id: rsvpHov; cursorShape: Qt.PointingHandCursor }
                            Text {
                                id: rsvpLbl
                                anchors.centerIn: parent
                                text: modelData.cap + "  " + modelData.label
                                color: Theme.fg
                                font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                            }
                            TapHandler { onTapped: Backend.rsvpMail(msgId, modelData.status) }
                        }
                    }
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
                                        anchors.centerIn: parent
                                        text: attChip.hintLabel
                                        color: attChip.hintDim ? Theme.fg_muted : Theme.fg
                                        font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                                    }
                                }
                                Text {
                                    id: chipText
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
                    visible: !dl.inVisual
                    width: parent.width
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    // Html.colorLinks because linkColor is a no-op for RichText
                    text: Html.colorLinks((cv.hinting && index === cv.hintIndex) ? cv.hintedHtml
                          : (cv.yanking && index === cv.yankIndex) ? cv.yankHtml
                          : (modelData.bodyRich || ""))
                    color: Theme.fg_secondary
                    font.family: Theme.fontFamily
                    font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 14
                    onLinkActivated: link => cv.openLink(link)

                    function computeRects() {
                        if (!(cv.hinting && index === cv.hintIndex)) return
                        const doc = geom.getText(0, geom.length)
                        const widths = cv._imgWidths(geom)
                        const imgPos = []
                        for (let ip = doc.indexOf("\uFFFC"); ip >= 0; ip = doc.indexOf("\uFFFC", ip + 1))
                            imgPos.push(ip)
                        const rects = []
                        let from = 0, lastImg = -1, stack = 0
                        for (let k = 0; k + cv.hintAttCount < cv.hintLabels.length; k++) {
                            const lab = cv.hintLabels[cv.hintAttCount + k]
                            const kind = cv.hintKinds[k] || "link"
                            if (kind === "link") {
                                const p = doc.indexOf("\u200B", from)
                                if (p < 0) continue
                                from = p + 1
                                const r1 = geom.positionToRectangle(p + 1)
                                const r2 = geom.positionToRectangle(p + 1 + lab.length + 2)
                                rects.push({ x: r1.x, y: r1.y, w: Math.max(r2.x - r1.x, 16), h: r1.height, label: lab })
                                continue
                            }
                            const ti = cv.hintImgTargets[k]
                            if (ti === undefined || ti < 0 || ti >= imgPos.length) continue
                            const ipos = imgPos[ti]
                            const ir = geom.positionToRectangle(ipos)
                            const iw = cv._objWidth(geom, ipos, ti, widths)
                            const tiny = iw < 48 || ir.height < 22
                            stack = (ipos === lastImg) ? stack + 1 : 0
                            lastImg = ipos
                            let ring = null
                            if (stack === 0) {
                                let rx = ir.x, ry = ir.y, rw = iw, rb = ir.y + ir.height
                                const tail = kind === "imglink" ? (cv.hintInners[k] || "") : ""
                                if (tail.length > 2) {
                                    const tpos = doc.indexOf(tail, ipos)
                                    if (tpos >= 0) {
                                        const le = geom.positionAt(1e6, geom.positionToRectangle(tpos).y + 4)
                                        const er = geom.positionToRectangle(le)
                                        rb = Math.max(rb, er.y + er.height)
                                        rw = Math.max(rw, er.x - rx)
                                    }
                                }
                                ring = { x: rx - 4, y: ry - 4, w: rw + 8, h: rb - ry + 8 }
                            }
                            const inside = iw >= 140 && ir.height >= 48
                            rects.push({ x: tiny ? ir.x
                                            : inside ? ir.x + 6 + stack * 52 : ir.x + iw + 8 + stack * 52,
                                         y: tiny ? ir.y + (ir.height - 18) / 2
                                            : inside ? ir.y + 6 : ir.y + (ir.height - 18) / 2,
                                         w: 30, h: 18, label: lab, kind: kind, ring: ring })
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
                            id: hintCap
                            required property var modelData
                            readonly property bool dim: cv.hintBuf !== "" && modelData.label.indexOf(cv.hintBuf) !== 0
                            readonly property bool onImage: !!modelData.kind
                            x: modelData.x
                            y: modelData.y + (modelData.h - height) / 2
                            width: onImage ? capRow.implicitWidth + 12 : modelData.w
                            height: 18
                            radius: 5
                            border.width: dim ? 0 : 1
                            border.color: Theme.hairline
                            color: dim ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
                            Rectangle {
                                visible: hintCap.onImage && !hintCap.dim
                                x: hintCap.modelData.ring ? hintCap.modelData.ring.x - hintCap.x : 0
                                y: hintCap.modelData.ring ? hintCap.modelData.ring.y - hintCap.y : 0
                                width: hintCap.modelData.ring ? hintCap.modelData.ring.w : 0
                                height: hintCap.modelData.ring ? hintCap.modelData.ring.h : 0
                                color: "transparent"
                                border.width: 1
                                border.color: Theme.sky
                                radius: 4
                            }
                            Row {
                                id: capRow
                                anchors.centerIn: parent
                                spacing: 3
                                // multi-action images: the icon says what this cap does
                                Icon {
                                    visible: hintCap.onImage
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 11; height: 11
                                    name: hintCap.modelData.kind === "imglink" ? "link" : "image"
                                    color: hintCap.dim ? Theme.fg_muted : Theme.fg
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: hintCap.modelData.label
                                    color: hintCap.dim ? Theme.fg_muted : Theme.fg
                                    font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                                }
                            }
                        }
                    }

                    function computeYankRects() {
                        if (!(cv.yanking && index === cv.yankIndex)) return
                        const doc = geom.getText(0, geom.length)
                        const widths = cv._imgWidths(geom)
                        const imgPos = []
                        for (let ip = doc.indexOf("\uFFFC"); ip >= 0; ip = doc.indexOf("\uFFFC", ip + 1))
                            imgPos.push(ip)
                        const rects = []
                        let from = 0
                        for (let k = 0; k < cv.yankTokens.length; k++) {
                            const lab = cv.yankLabels[k]
                            if (!lab) break
                            const t = cv.yankTokens[k]
                            if (t.img) {
                                if (t.ord === undefined || t.ord >= imgPos.length) continue
                                const ipos = imgPos[t.ord]
                                const ir = geom.positionToRectangle(ipos)
                                const iw = cv._objWidth(geom, ipos, t.ord, widths)
                                const inside = iw >= 140 && ir.height >= 48
                                rects.push({ x: inside ? ir.x + 6 : ir.x + iw + 8,
                                             y: inside ? ir.y + 6 : ir.y + (ir.height - 18) / 2,
                                             w: 30, h: 18, label: lab, kind: "img" })
                                continue
                            }
                            const p = doc.indexOf("\u200B", from)
                            if (p < 0) continue
                            from = p + 1
                            const r1 = geom.positionToRectangle(p + 1)
                            const r2 = geom.positionToRectangle(p + 1 + lab.length + 2)
                            rects.push({ x: r1.x, y: r1.y, w: Math.max(r2.x - r1.x, 16), h: r1.height, label: lab })
                        }
                        cv.yankRects = rects
                    }
                    Connections {
                        target: cv
                        function onYankingChanged() {
                            if (cv.yanking && index === cv.yankIndex) Qt.callLater(bodyText.computeYankRects)
                        }
                    }
                    Item {
                        readonly property bool on: !!cv.pickFlash && dl.index === cv.pickFlashIndex
                        z: 5
                        property var r: null
                        onOnChanged: if (on) r = cv.pickFlash
                        opacity: on ? 1 : 0
                        visible: r !== null && opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                        x: r ? r.x : 0
                        y: r ? r.y + (r.h - 18) / 2 : 0
                        Rectangle {
                            width: 26; height: 18; radius: 5
                            border.width: 1; border.color: Theme.cursor
                            color: Theme.mode === "light" ? Theme.bg : Theme.surface2
                            Text {
                                renderTypeQuality: Text.VeryHighRenderTypeQuality
                                anchors.centerIn: parent
                                text: ""; color: Theme.cursor
                                font.family: Theme.fontFamily; font.pixelSize: 12
                                scale: parent.parent.on ? 1 : 0.25
                                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                            }
                        }
                    }
                    Repeater {
                        model: (cv.yanking && index === cv.yankIndex) ? cv.yankRects : []
                        delegate: Rectangle {
                            id: yankCap
                            required property var modelData
                            readonly property bool dim: cv.yankBuf !== "" && modelData.label.indexOf(cv.yankBuf) !== 0
                            readonly property bool picked: !!cv.pickFlash && modelData.label === cv.yankBuf
                            opacity: picked ? 0 : 1
                            readonly property bool onImage: modelData.kind === "img"
                            x: modelData.x
                            y: modelData.y + (modelData.h - height) / 2
                            width: onImage ? yankCapRow.implicitWidth + 12 : modelData.w
                            height: 18
                            radius: 5
                            border.width: dim ? 0 : 1
                            border.color: Theme.hairline
                            color: dim ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
                            Row {
                                id: yankCapRow
                                anchors.centerIn: parent
                                spacing: 3
                                Icon {
                                    visible: yankCap.onImage
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 11; height: 11
                                    name: "image"
                                    color: yankCap.dim ? Theme.fg_muted : Theme.fg
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: yankCap.modelData.label
                                    color: yankCap.dim ? Theme.fg_muted : Theme.fg
                                    font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                                }
                            }
                        }
                    }
                }

                // layout twin of bodyText: same document, same width, same font.
                // Invisible it serves the hint geometry (positionToRectangle);
                // in visual mode it swaps in as the selectable renderer.
                TextEdit {
                    id: geom
                    visible: dl.inVisual
                    width: bodyText.width
                    textFormat: TextEdit.RichText
                    wrapMode: TextEdit.Wrap
                    font: bodyText.font
                    text: bodyText.text
                    color: Theme.fg_secondary
                    readOnly: true
                    activeFocusOnPress: false
                    selectByMouse: false
                    selectByKeyboard: false
                    // nvim parity: Visual bg = bg_selection (dark) / bg_surface3
                    // (light — selection is ~3/255 off the card there); fg untouched
                    selectionColor: Theme.mode === "light" ? Theme.surface3 : Theme.selection
                    selectedTextColor: Theme.fg_secondary
                    onLinkActivated: link => cv.openLink(link)
                    onWidthChanged: if (dl.inVisual) Qt.callLater(cv._buildLineRects)
                    onTextChanged: if (dl.inVisual) Qt.callLater(cv._buildLineRects)

                    // vim block cursor: sits ON the cursor char (cursorDelegate
                    // would sit after it), glyph reads through the tint
                    Rectangle {
                        visible: dl.inVisual && cv.showCursor && cv.selC >= 0 && !cv.hinting && !cv.yanking
                        readonly property rect cr: (dl.inVisual && cv.selC >= 0)
                            ? geom.positionToRectangle(cv.selC) : Qt.rect(0, 0, 0, 0)
                        readonly property rect cn: (dl.inVisual && cv.selC >= 0)
                            ? geom.positionToRectangle(Math.min(cv.selC + 1, geom.length)) : Qt.rect(0, 0, 0, 0)
                        x: cr.x
                        y: onObject ? cr.y : cr.y + (cr.height - height) / 2
                        height: onObject ? cr.height : Math.min(cr.height, 26)
                        width: (cn.y === cr.y && cn.x > cr.x) ? cn.x - cr.x
                               : onObject ? cv.objWidthAt(cv.selC) : 8
                        // on an image cell the block would hide what's selected —
                        // render a focus ring instead so the image shows through
                        readonly property bool onObject: dl.inVisual && cv.selC >= 0
                            && geom.getText(cv.selC, cv.selC + 1) === "\uFFFC"
                        color: onObject ? "transparent" : Theme.cursor
                        border.width: onObject ? 2 : 0
                        border.color: Theme.cursor
                        radius: onObject ? 4 : 2
                        // terminal-style: solid block, char redrawn on top
                        Text {
                            anchors.centerIn: parent
                            text: {
                                if (!(dl.inVisual && cv.selC >= 0)) return ""
                                const ch = geom.getText(cv.selC, cv.selC + 1)
                                return /[\s\uFFFC]/.test(ch) ? "" : ch
                            }
                            color: Theme.bg
                            font: geom.font
                        }
                    }

                    // copied image flashes itself (card flash covers text copies)
                    Rectangle {
                        id: imgCopyFlash
                        property bool showCopy: false
                        // geometry persists through the fade-out (clearing the
                        // shared rect mid-fade collapsed the veil abruptly)
                        property var r: null
                        visible: r !== null && opacity > 0
                        opacity: showCopy ? 0.55 : 0
                        x: r ? r.x : 0
                        y: r ? r.y : 0
                        width: r ? r.w : 0
                        height: r ? r.h : 0
                        radius: 4
                        color: Theme.mode === "light" ? Theme.surface3 : Theme.selection
                        border.width: 1
                        border.color: Theme.cursor
                        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                        Connections {
                            target: Backend
                            function onCopyPulseChanged() {
                                if (dl.index === list.currentIndex && cv.copyFlashRect) {
                                    imgCopyFlash.r = cv.copyFlashRect
                                    imgCopyFlash.showCopy = true; imgFlashRevert.restart()
                                }
                            }
                        }
                        Timer {
                            id: imgFlashRevert
                            interval: 1200
                            onTriggered: { imgCopyFlash.showCopy = false; cv.copyFlashRect = null }
                        }
                    }

                    // native selection paints text only — selected inline
                    // images get the family selection tint as a fill veil
                    Repeater {
                        model: dl.inVisual ? cv.imgSelRects : []
                        delegate: Rectangle {
                            required property var modelData
                            x: modelData.x; y: modelData.y
                            width: modelData.w; height: modelData.h
                            color: Theme.mode === "light" ? Theme.surface3 : Theme.selection
                            opacity: 0.6
                            radius: 4
                        }
                    }

                    Item {
                        readonly property bool on: !!cv.pickFlash && dl.index === cv.pickFlashIndex
                        z: 5
                        property var r: null
                        onOnChanged: if (on) r = cv.pickFlash
                        opacity: on ? 1 : 0
                        visible: r !== null && opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                        x: r ? r.x : 0
                        y: r ? r.y + (r.h - 18) / 2 : 0
                        Rectangle {
                            width: 26; height: 18; radius: 5
                            border.width: 1; border.color: Theme.cursor
                            color: Theme.mode === "light" ? Theme.bg : Theme.surface2
                            Text {
                                renderTypeQuality: Text.VeryHighRenderTypeQuality
                                anchors.centerIn: parent
                                text: ""; color: Theme.cursor
                                font.family: Theme.fontFamily; font.pixelSize: 12
                                scale: parent.parent.on ? 1 : 0.25
                                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                            }
                        }
                    }
                    // yank caps likewise render on the cursor-mode surface
                    Repeater {
                        model: (cv.yanking && index === cv.yankIndex) ? cv.yankRects : []
                        delegate: Rectangle {
                            id: gYankCap
                            required property var modelData
                            readonly property bool dim: cv.yankBuf !== "" && modelData.label.indexOf(cv.yankBuf) !== 0
                            readonly property bool picked: !!cv.pickFlash && modelData.label === cv.yankBuf
                            opacity: picked ? 0 : 1
                            readonly property bool onImage: modelData.kind === "img"
                            x: modelData.x
                            y: modelData.y + (modelData.h - height) / 2
                            width: onImage ? gYankRow.implicitWidth + 12 : modelData.w
                            height: 18
                            radius: 5
                            border.width: dim ? 0 : 1
                            border.color: Theme.hairline
                            color: dim ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
                            Row {
                                id: gYankRow
                                anchors.centerIn: parent
                                spacing: 3
                                Icon {
                                    visible: gYankCap.onImage
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 11; height: 11
                                    name: "image"
                                    color: gYankCap.dim ? Theme.fg_muted : Theme.fg
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: gYankCap.modelData.label
                                    color: gYankCap.dim ? Theme.fg_muted : Theme.fg
                                    font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                                }
                            }
                        }
                    }

                    // hint caps must also render when geom is the visible
                    // host (f from NORMAL keeps cursor mode alive)
                    Repeater {
                        model: (cv.hinting && index === cv.hintIndex) ? cv.hintRects : []
                        delegate: Rectangle {
                            id: gHintCap
                            required property var modelData
                            readonly property bool dim: cv.hintBuf !== "" && modelData.label.indexOf(cv.hintBuf) !== 0
                            readonly property bool onImage: !!modelData.kind
                            x: modelData.x
                            y: modelData.y + (modelData.h - height) / 2
                            width: onImage ? gCapRow.implicitWidth + 12 : modelData.w
                            height: 18
                            radius: 5
                            border.width: dim ? 0 : 1
                            border.color: Theme.hairline
                            color: dim ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
                            Rectangle {
                                visible: !!gHintCap.modelData.ring && !gHintCap.dim
                                x: gHintCap.modelData.ring ? gHintCap.modelData.ring.x - gHintCap.x : 0
                                y: gHintCap.modelData.ring ? gHintCap.modelData.ring.y - gHintCap.y : 0
                                width: gHintCap.modelData.ring ? gHintCap.modelData.ring.w : 0
                                height: gHintCap.modelData.ring ? gHintCap.modelData.ring.h : 0
                                color: "transparent"
                                border.width: 1
                                border.color: Theme.sky
                                radius: 4
                            }
                            Row {
                                id: gCapRow
                                anchors.centerIn: parent
                                spacing: 3
                                Icon {
                                    visible: gHintCap.onImage
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 11; height: 11
                                    name: gHintCap.modelData.kind === "imglink" ? "link" : "image"
                                    color: gHintCap.dim ? Theme.fg_muted : Theme.fg
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: gHintCap.modelData.label
                                    color: gHintCap.dim ? Theme.fg_muted : Theme.fg
                                    font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                                }
                            }
                        }
                    }

                    // orange bar marks the current line; morphs into a copy
                    // icon on yank (same 250ms icon-swap as slqs/dsqrd)
                    Item {
                        id: gutterMark
                        visible: dl.inVisual && cv.lineRects.length > 0
                        readonly property var lr: cv.lineRects[Math.min(cv.curLine, Math.max(0, cv.lineRects.length - 1))] || null
                        x: -30; width: 16; height: 16
                        y: lr ? lr.y + (lr.h - height) / 2 : 0
                        property bool showCopy: false
                        Connections {
                            target: Backend
                            function onCopyPulseChanged() {
                                if (dl.index === list.currentIndex && !cv.pickFlash && !cv.copyFlashRect) {
                                    gutterMark.showCopy = true; gutterRevert.restart()
                                }
                            }
                        }
                        Timer { id: gutterRevert; interval: 1500; onTriggered: gutterMark.showCopy = false }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 3; height: 16; radius: 2; color: Theme.cursor
                            opacity: gutterMark.showCopy ? 0 : 1
                            scale: gutterMark.showCopy ? 0.25 : 1
                            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                        }
                        Text {
                            renderTypeQuality: Text.VeryHighRenderTypeQuality
                            anchors.centerIn: parent
                            text: ""; color: Theme.cursor
                            font.family: Theme.fontFamily; font.pixelSize: 16
                            opacity: gutterMark.showCopy ? 1 : 0
                            scale: gutterMark.showCopy ? 1 : 0.25
                            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                        }
                    }
                    // relative display-line gutter in the left strip: 14k/12j
                    // are aimed, not guessed (dsqrd/slqs gutter spec)
                    Repeater {
                        model: dl.inVisual ? cv.lineRects : []
                        delegate: Text {
                            required property var modelData
                            required property int index
                            readonly property int rel: Math.abs(index - cv.curLine)
                            x: -width - 20
                            y: modelData.y + (modelData.h - height) / 2
                            text: rel === 0 ? "" : rel
                            color: Theme.fg_secondary
                            font.family: Theme.fontFamily
                            font.hintingPreference: Font.PreferNoHinting
                            font.pixelSize: 11; font.weight: 500
                            font.features: ({ "tnum": 1 })
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
        // transparent so the card's rounded bottom corners stay rounded
        color: "transparent"

        Row {
            anchors { left: parent.left; leftMargin: 24; right: parent.right; rightMargin: 14; top: parent.top }
            height: 26; spacing: 8
            // the toggle only exists when reply-all actually adds anyone
            readonly property bool hasAudience: cv.computeRecipients(true).cc.length > 0
            Text {
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
                // quiet keycap chip, not the loud accent pill — this is
                // status, not an alert
                color: cv.replyAll ? Theme.surface2 : "transparent"
                border.width: 1
                border.color: Theme.hairline
                Text {
                    id: allLbl
                    anchors.centerIn: parent
                    text: cv.replyAll ? "+" + cv.replyExtras() + " all" : "sender only"
                    color: cv.replyAll ? Theme.fg_secondary : Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                }
                TapHandler { onTapped: cv.replyAll = !cv.replyAll }
            }
        }

        // insert-mode chat field, same focus language as the chat composers
        Rectangle {
            id: inputBox
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                      // 14 on all sides: even against the card edge AND concentric
                      // (card radius 24 − inset 14 = the input's radius)
                      leftMargin: 14; rightMargin: 14; bottomMargin: 14 }
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
                    placeholderText: "Reply to " + cv.replyTargetName() + "…"
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

    // Scroll position indicator — traces the card's own edge: bends around
    // the top-right corner arc, runs the right edge, bends out at the bottom.
    // Pure indicator (no interaction); glides along the path and fades idle.
    Canvas {
        id: scrollHint
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Theme.radiusCard + 12
        // default Image target: FramebufferObject rasterizes at logical
        // resolution, so on fractional-scale outputs (laptop @1.75) the
        // corner sweep upscaled into an angular hockey-stick kink
        visible: opacity > 0 && frac < 1
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        readonly property real span: list.contentHeight + list.topMargin + list.bottomMargin
        readonly property real frac: Math.min(1, list.height / Math.max(1, span))
        readonly property real off: 5                      // stroke inset from the edge
        property real pos: 0                               // 0..1, eased along the path
        Behavior on pos { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        onPosChanged: requestPaint()
        onFracChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()

        Connections {
            target: list
            function onContentYChanged() {
                const top = list.originY - list.topMargin
                const range = scrollHint.span - list.height
                scrollHint.pos = range > 0 ? Math.max(0, Math.min(1, (list.contentY - top) / range)) : 0
                scrollHint.opacity = 1
                scrollHintFade.restart()
            }
        }
        Timer { id: scrollHintFade; interval: 900; onTriggered: scrollHint.opacity = 0 }

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const W = width, H = height
            const R = Theme.radiusCard
            const r = R - off                             // stroke centerline radius
            // full quarter sweep drawn with real arcs — the corner hook IS the
            // card corner's curvature. (A sampled polyline gave the short arc
            // ~4 segments and it read as an angled kink on hidpi panels.)
            const SW = Math.PI / 2
            const arc = SW * r
            const edge = Math.max(0, H - 2 * R)
            const total = arc + edge + arc
            const pill = Math.max(44, frac * total)
            const t0 = pos * (total - pill)
            const t1 = t0 + pill
            ctx.strokeStyle = String(Theme.cursor)
            ctx.lineWidth = 4.5
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            ctx.beginPath()
            if (t0 < arc) {                               // start inside the top corner
                ctx.arc(W - R, R, r, -SW + (t0 / arc) * SW,
                        Math.min(0, -SW + (t1 / arc) * SW))
            } else if (t0 < arc + edge) {                 // start on the straight edge
                ctx.moveTo(W - off, R + (t0 - arc))
            } else {                                      // start inside the bottom corner
                const a = ((t0 - arc - edge) / arc) * SW
                ctx.moveTo(W - R + r * Math.cos(a), H - R + r * Math.sin(a))
            }
            if (t1 > arc && t0 < arc + edge && edge > 0)  // straight right edge
                ctx.lineTo(W - off, R + Math.min(edge, t1 - arc))
            if (t1 > arc + edge)                          // bottom corner
                ctx.arc(W - R, H - R, r,
                        Math.max(0, (t0 - arc - edge) / arc) * SW,
                        Math.min(1, (t1 - arc - edge) / arc) * SW)
            ctx.stroke()
        }
    }

    Text {
        anchors.centerIn: parent
        visible: list.count === 0
        text: "loading…"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13
    }
}
