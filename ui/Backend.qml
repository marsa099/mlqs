pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: backend

    property var workspaces: []
    property string currentAccount: ""
    property var folders: []
    property string currentFolderId: ""
    property string currentFolderName: ""
    // ListModel, not a JS array: in-place setProperty/insert/remove keep the
    // ListView's delegates and cursor alive (array replacement rebuilds all
    // rows — the cursor "blink" on every read/star toggle)
    readonly property var convs: convsModel
    ListModel { id: convsModel }
    property string nextCursor: ""
    property string pendingCursor: ""
    property bool loadingConvs: false
    property var messages: []
    property string openConvId: ""
    property string openConvSubject: ""

    // flat display row for the ListModel (nested arrays don't survive it)
    // Gmail digests label changes lazily: a sync tick in the gap after
    // markread still reports UNREAD (same race the daemon dodges for folder
    // counts) and would re-bold a row we just read — with nothing after to
    // correct it. Recently-read threads hold their local read state.
    property var readGrace: ({})

    function toRow(c) {
        const graced = (Date.now() - (readGrace[c.id] || 0)) < 90000
        return {
            tid: c.id, subject: c.subject || "", snippet: c.snippet || "",
            who: senderLine(c) + ((c.msgCount || 1) > 1 ? " (" + c.msgCount + ")" : ""),
            dateStr: fmtDate(c.date), dateMs: new Date(c.date).getTime(),
            unread: !!c.unread && !graced, starred: !!c.starred
        }
    }
    function findRow(id) {
        for (let i = 0; i < convsModel.count; i++)
            if (convsModel.get(i).tid === id) return i
        return -1
    }

    // inbox unread per account (tab badges for the non-active accounts)
    property var accountUnread: ({})

    signal toast(string text)
    signal summonRequested()
    signal dismissRequested()
    signal contactsResult(var items, string query)
    function queryContacts(q) { send({ type: "contacts", account: currentAccount, query: q }) }

    function cycleAccount(d) {
        if (workspaces.length < 2) return
        const n = workspaces.length
        const i = workspaces.findIndex(w => w.id === currentAccount)
        selectAccount(workspaces[(i + (d || 1) + n) % n].id)
    }

    function safeWrite(s) { if (sock.connected) sock.write(s) }
    function send(obj) { safeWrite(JSON.stringify(obj) + "\n") }

    function selectAccount(id) {
        currentAccount = id
        folders = []; convsModel.clear(); messages = []
        openConvId = ""; currentFolderId = ""
        send({ type: "folders", account: id })
    }

    // single-key folder jumps (i inbox, s sent, …)
    function jumpRole(role) {
        const f = folders.find(f => f.role === role)
        if (f) selectFolder(f.id, f.name)
    }

    function selectThreads() {
        currentFolderId = "__threads"; currentFolderName = "Threads"
        convsModel.clear(); nextCursor = ""; pendingCursor = ""
        openConvId = ""; messages = []
        loadingConvs = true
        send({ type: "threads", account: currentAccount })
    }

    // _loadFolder switches the index WITHOUT touching an open conversation —
    // the folders-event auto-select must not clobber a deep-linked conv
    function _loadFolder(id, name) {
        currentFolderId = id; currentFolderName = name || id
        convsModel.clear(); nextCursor = ""; pendingCursor = ""
        loadingConvs = true
        send({ type: "conversations", account: currentAccount, folder: id })
    }
    function selectFolder(id, name) {
        if (id === "__threads") { selectThreads(); return }
        openConvId = ""; messages = []
        _loadFolder(id, name)
    }

    function loadMore() {
        if (nextCursor === "" || loadingConvs) return
        pendingCursor = nextCursor
        loadingConvs = true
        send({ type: "conversations", account: currentAccount, folder: currentFolderId, cursor: nextCursor })
    }

    // mark-read is deferred until the conversation payload arrives — sent
    // eagerly it races the fetch and the per-message "new" flags come back
    // already cleared
    property string pendingRead: ""

    function openConv(row) {
        if (!row || !row.tid) return
        openConvId = row.tid
        openConvSubject = row.subject || "(no subject)"
        messages = []
        pendingRead = row.unread ? row.tid : ""
        send({ type: "conversation", account: currentAccount, id: row.tid })
    }

    function setLocalRead(id, read) {
        if (read) readGrace[id] = Date.now()
        else delete readGrace[id]
        const i = findRow(id)
        if (i >= 0) convsModel.setProperty(i, "unread", !read)
        folders = folders.map(f => f.id === currentFolderId
            ? Object.assign({}, f, { unread: Math.max(0, (f.unread || 0) + (read ? -1 : 1)) }) : f)
    }

    // Shift+R in the index: flip a thread's read state (server + local)
    function toggleRead(row) {
        if (!row || !row.tid) return
        const read = !!row.unread   // unread → mark read; read → mark unread
        send({ type: "markread", account: currentAccount, id: row.tid, text: read ? "true" : "false" })
        setLocalRead(row.tid, read)
    }

    function closeConv() { openConvId = ""; messages = [] }

    function toggleStar(row) {
        if (!row || !row.tid) return
        const v = !row.starred
        send({ type: "star", account: currentAccount, id: row.tid, text: v ? "true" : "false" })
        const i = findRow(row.tid)
        if (i >= 0) convsModel.setProperty(i, "starred", v)
    }

    // one-level undo for destructive moves (u) — Gmail restores server-side.
    // Holds a LIST so visual-mode batches undo as one unit.
    property var lastRemoved: null

    function _snapRow(i) {
        const r = convsModel.get(i)
        return { idx: i, row: { tid: r.tid, subject: r.subject, snippet: r.snippet, who: r.who,
                                dateStr: r.dateStr, dateMs: r.dateMs, unread: r.unread, starred: r.starred } }
    }

    function _removeMany(kind, ids) {
        const items = []
        for (const id of ids) {
            const i = findRow(id)
            if (i >= 0) items.push(_snapRow(i))
        }
        if (items.length === 0) return 0
        lastRemoved = { kind: kind, account: currentAccount, folderId: currentFolderId, items: items }
        for (const it of items) {
            send({ type: kind, account: currentAccount, id: it.row.tid })
            removeLocal(it.row.tid)
        }
        return items.length
    }

    function archiveConv(id) {
        if (_removeMany("archive", [id])) toast("archived — u undoes")
    }
    function trashConv(id) {
        if (_removeMany("trash", [id])) toast("trashed — u undoes")
    }
    function batchArchive(ids) {
        const n = _removeMany("archive", ids)
        if (n) toast(n + " archived — u undoes")
    }
    function batchTrash(ids) {
        const n = _removeMany("trash", ids)
        if (n) toast(n + " trashed — u undoes")
    }
    // rows: model rows; if any unread → all read, else all unread
    function batchRead(rows) {
        if (!rows.length) return
        const read = rows.some(r => r.unread)
        for (const r of rows) {
            if (!!r.unread !== read) continue
            send({ type: "markread", account: currentAccount, id: r.tid, text: read ? "true" : "false" })
            setLocalRead(r.tid, read)
        }
        toast(read ? "marked read" : "marked unread")
    }
    function batchStar(rows) {
        if (!rows.length) return
        const star = rows.some(r => !r.starred)
        for (const r of rows) {
            if (!!r.starred === star) continue
            send({ type: "star", account: currentAccount, id: r.tid, text: star ? "true" : "false" })
            const i = findRow(r.tid)
            if (i >= 0) convsModel.setProperty(i, "starred", star)
        }
        toast(star ? "starred" : "unstarred")
    }

    function undoRemove() {
        const lr = lastRemoved
        if (!lr) { toast("nothing to undo"); return }
        lastRemoved = null
        const verb = lr.kind === "trash" ? "untrash" : "unarchive"
        // reinsert in ascending original order so indices land right
        const items = lr.items.slice().sort((a, b) => a.idx - b.idx)
        for (const it of items) {
            send({ type: verb, account: lr.account, id: it.row.tid })
            if (lr.account === currentAccount && lr.folderId === currentFolderId) {
                convsModel.insert(Math.min(it.idx, convsModel.count), it.row)
                if (it.row.unread)
                    folders = folders.map(f => f.id === currentFolderId
                        ? Object.assign({}, f, { unread: (f.unread || 0) + 1 }) : f)
            }
        }
        toast((items.length > 1 ? items.length + " " : "") + (lr.kind === "trash" ? "restored from trash" : "restored to inbox"))
    }

    function removeLocal(id) {
        const i = findRow(id)
        if (i >= 0) {
            if (convsModel.get(i).unread)
                folders = folders.map(f => f.id === currentFolderId
                    ? Object.assign({}, f, { unread: Math.max(0, (f.unread || 0) - 1) }) : f)
            convsModel.remove(i)
        }
        if (openConvId === id) closeConv()
    }

    function openAttachment(msgId, att) {
        if (!att) return
        send({ type: "openatt", account: currentAccount, id: msgId,
               text: att.id || "", query: att.contentId || "", folder: att.name || "" })
    }

    function openHtml(msgId) {
        send({ type: "openhtml", account: currentAccount, id: openConvId, text: msgId })
    }

    function refresh() {
        if (currentFolderId !== "") selectFolder(currentFolderId, currentFolderName)
    }

    // optimistic echo: a sent reply appears in the open conversation
    // immediately (chat-client behavior), not after the next sync
    function appendLocalMessage(d) {
        if (openConvId === "") return
        const me = workspaces.find(w => w.id === currentAccount) || {}
        const esc = (d.body || "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
            .replace(/\n/g, "<br>")
        messages = messages.concat([{
            id: "local-" + Date.now(), convId: openConvId,
            from: { name: "me", email: me.email || "" },
            to: [], cc: [], subject: d.subject || "", snippet: "",
            date: new Date().toISOString(), unread: false, starred: false,
            attachments: [],
            bodyRich: '<div style="line-height:140%">' + esc + "</div>",
            hasHtml: false, sending: true, local: true
        }])
    }

    function sendMail(d) {
        send({ type: "send", account: currentAccount,
               to: d.to || "", cc: d.cc || "", bcc: d.bcc || "",
               subject: d.subject || "", body: d.body || "",
               replyTo: d.replyTo || "", conv: d.conv || "",
               forward: d.forward || "", paths: d.paths || [] })
    }

    // ── calendar agenda (merged across accounts) ──
    readonly property var events: eventsModel
    ListModel { id: eventsModel }
    property bool loadingAgenda: false
    property var _agendaByAccount: ({})

    function selectCalendar() {
        currentFolderId = "__calendar"; currentFolderName = "Calendar"
        openConvId = ""; messages = []
        refreshAgenda()
    }
    property int agendaDays: 7   // 1 today · 7 week · 31 month
    function setAgendaSpan(days) {
        if (agendaDays === days) return
        agendaDays = days
        refreshAgenda()
    }
    function refreshAgenda() {
        _agendaByAccount = {}
        eventsModel.clear()
        loadingAgenda = true
        for (const w of workspaces) send({ type: "agenda", account: w.id, text: String(agendaDays) })
    }
    function _rebuildAgenda() {
        eventsModel.clear()
        let all = []
        for (const acct in _agendaByAccount)
            for (const ev of _agendaByAccount[acct]) all.push(Object.assign({ account: acct }, ev))
        all.sort((a, b) => new Date(a.start) - new Date(b.start))
        // the same event often exists on both accounts' calendars — collapse,
        // preferring the copy that carries my RSVP status
        const seen = {}, out = []
        for (const ev of all) {
            const k = (ev.iCalUid || ev.id) + "|" + ev.start
            if (seen[k] === undefined) { seen[k] = out.length; out.push(ev) }
            else if (!out[seen[k]].myStatus && ev.myStatus) out[seen[k]] = ev
        }
        for (const ev of out) eventsModel.append(toEventRow(ev))
    }
    function toEventRow(ev) {
        const s = new Date(ev.start), e = new Date(ev.end)
        return {
            eid: ev.id, calId: ev.calId, account: ev.account,
            title: ev.title || "(untitled)", location: ev.location || "",
            startMs: s.getTime(), dayKey: dayKey(s),
            timeStr: ev.allDay ? "all day" : Qt.formatTime(s, "hh:mm") + "–" + Qt.formatTime(e, "hh:mm"),
            allDay: !!ev.allDay, meetLink: ev.meetLink || "", htmlLink: ev.htmlLink || "",
            myStatus: ev.myStatus || "", organizer: ev.organizer || "",
            attendeeCount: (ev.attendees || []).length
        }
    }
    function dayKey(d) {
        const now = new Date()
        const tomorrow = new Date(now.getTime() + 86400000)
        if (d.toDateString() === now.toDateString()) return "Today — " + Qt.formatDate(d, "ddd MMM d")
        if (d.toDateString() === tomorrow.toDateString()) return "Tomorrow — " + Qt.formatDate(d, "ddd MMM d")
        return Qt.formatDate(d, "dddd — MMM d")
    }
    function rsvp(row, status) {
        send({ type: "rsvp", account: row.account, folder: row.calId, id: row.eid, text: status })
        for (let i = 0; i < eventsModel.count; i++)
            if (eventsModel.get(i).eid === row.eid) eventsModel.setProperty(i, "myStatus", status)
    }
    function rsvpMail(msgId, status) {
        send({ type: "rsvpmail", account: currentAccount, conv: openConvId, id: msgId, text: status })
        toast("rsvp: " + status + "…")
    }
    function createEvent(d) {
        send({ type: "createevent", account: d.account || currentAccount,
               folder: d.calId || "", subject: d.title || "", query: d.location || "",
               body: d.notes || "", to: d.attendees || "",
               start: d.start, end: d.end, meet: !!d.meet })
    }

    // target-calendar list for the event composer's picker
    property var accountCalendars: []
    function requestCalendars() { send({ type: "calendars", account: currentAccount }) }

    function runSearch(q) {
        if (!q) return
        convsModel.clear(); nextCursor = ""; pendingCursor = ""
        currentFolderId = ""; currentFolderName = "search: " + q
        openConvId = ""
        loadingConvs = true
        send({ type: "search", account: currentAccount, query: q })
    }

    // "10:16" today, "Jul 9" this year, "2025-11-03" older
    function fmtDate(iso) {
        if (!iso) return ""
        const d = new Date(iso)
        const now = new Date()
        if (d.toDateString() === now.toDateString())
            return Qt.formatTime(d, "hh:mm")
        if (d.getFullYear() === now.getFullYear())
            return Qt.formatDate(d, "MMM d")
        return Qt.formatDate(d, "yyyy-MM-dd")
    }

    function senderLine(c) {
        const s = (c && c.senders) || []
        if (s.length === 0) return "?"
        const names = s.map(a => a.name || a.email)
        return names.slice(0, 2).join(", ") + (names.length > 2 ? " +" + (names.length - 2) : "")
    }

    function onEvent(line) {
        let e
        try { e = JSON.parse(line) } catch (err) { return }
        if (e.type === "workspaces") {
            workspaces = e.workspaces || []
            if (currentAccount === "" && workspaces.length > 0)
                selectAccount(workspaces[0].id)
            // seed every account's inbox count so tab badges work before
            // the account is ever visited (folders handler stores them all)
            for (const w of workspaces)
                if (w.id !== currentAccount) send({ type: "folders", account: w.id })
        } else if (e.type === "folders") {
            // track every account's inbox count for the tab badges
            const inboxF = (e.folders || []).find(f => f.role === "inbox")
            if (inboxF) {
                const m = Object.assign({}, accountUnread)
                m[e.account] = inboxF.unread || 0
                accountUnread = m
            }
            if (e.account !== currentAccount) return
            folders = (e.folders || []).map(f =>
                Object.assign({}, f, { section: f.role === "label" ? "labels" : "mailbox" }))
            if (currentFolderId === "") {
                const inbox = folders.find(f => f.role === "inbox")
                if (inbox) _loadFolder(inbox.id, inbox.name)
            }
        } else if (e.type === "conversations") {
            loadingConvs = false
            if (e.account !== currentAccount) return
            if ((e.folder || "") !== currentFolderId) return
            const items = e.items || []
            if (pendingCursor !== "") pendingCursor = ""
            else convsModel.clear()
            // later pages can overlap the stitched unread block — dedup
            for (const c of items) if (findRow(c.id) < 0) convsModel.append(toRow(c))
            nextCursor = e.next || ""
        } else if (e.type === "conversation") {
            if (e.id === openConvId) {
                messages = e.messages || []
                if (pendingRead === e.id) {
                    send({ type: "markread", account: currentAccount, id: e.id })
                    setLocalRead(e.id, true)
                    pendingRead = ""
                }
            }
        } else if (e.type === "convUpdated") {
            if (e.account !== currentAccount || !e.conv) return
            if (currentFolderId === "__threads") return
            const c = e.conv
            const inFolder = currentFolderId !== "" && (c.folderIds || []).indexOf(currentFolderId) >= 0
            const row = toRow(c)
            const i = findRow(c.id)
            if (!inFolder) {
                if (i >= 0) convsModel.remove(i)
                return
            }
            // unreads live above the read block; date-sorted within each
            let b = 0
            while (b < convsModel.count && convsModel.get(b).unread) b++
            let pos = row.unread ? 0 : b
            const hi = row.unread ? b : convsModel.count
            while (pos < hi && convsModel.get(pos).dateMs > row.dateMs
                   && convsModel.get(pos).tid !== c.id) pos++
            if (i < 0) convsModel.insert(pos, row)
            else if (i === pos) convsModel.set(i, row)
            else {
                convsModel.remove(i)
                if (pos > i) pos--
                convsModel.insert(pos, row)
            }
        } else if (e.type === "convRemoved") {
            if (e.account !== currentAccount) return
            const i = findRow(e.id)
            if (i >= 0) convsModel.remove(i)
            if (openConvId === e.id) closeConv()
        } else if (e.type === "openconv") {
            // notification deep-link: land on the conversation itself.
            // unread:true — it came from a notification, so mark-read must
            // fire after the fetch (badge + server state)
            if (e.account !== currentAccount) selectAccount(e.account)
            openConv({ tid: e.id, subject: e.subject || "", unread: true })
        } else if (e.type === "contacts") {
            contactsResult(e.items || [], e.query || "")
        } else if (e.type === "readmarked") {
            if (e.account === currentAccount) setLocalRead(e.id, true)
        } else if (e.type === "sent") {
            // resolve the optimistic echo's sending state
            messages = messages.map(m => m.sending ? Object.assign({}, m, { sending: false }) : m)
            toast("sent ✓")
        } else if (e.type === "agenda") {
            loadingAgenda = false
            const m = Object.assign({}, _agendaByAccount)
            m[e.account] = e.events || []
            _agendaByAccount = m
            if (currentFolderId === "__calendar") _rebuildAgenda()
        } else if (e.type === "calendars") {
            if (e.account === currentAccount) accountCalendars = e.calendars || []
        } else if (e.type === "rsvped") {
            toast("rsvp saved" + (e.status ? ": " + e.status : ""))
        } else if (e.type === "eventcreated") {
            toast("event created ✓")
            if (currentFolderId === "__calendar") refreshAgenda()
        } else if (e.type === "summon") {
            summonRequested()
        } else if (e.type === "dismiss") {
            dismissRequested()
        } else if (e.type === "toast") {
            if ((e.text || "").indexOf("mlqs send") === 0)
                messages = messages.map(m => m.sending ? Object.assign({}, m, { sending: false, failed: true }) : m)
            toast(e.text || "")
        }
    }

    Socket {
        id: sock
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/mlqs.sock"
        connected: true
        parser: SplitParser { onRead: data => backend.onEvent(data) }
        onConnectionStateChanged: {
            if (!connected) { reconnect.start(); return }
            // daemon re-sends workspaces on connect; refresh the open view too
            if (currentAccount !== "") {
                send({ type: "folders", account: currentAccount })
                if (currentFolderId === "__calendar") refreshAgenda()
                else if (currentFolderId !== "" && currentFolderId !== "__threads")
                    send({ type: "conversations", account: currentAccount, folder: currentFolderId })
                // an open conversation's fetch died with the old daemon —
                // re-request it or it shows "loading…" forever
                if (openConvId !== "")
                    send({ type: "conversation", account: currentAccount, id: openConvId })
            }
        }
    }

    Timer {
        id: reconnect
        interval: 1500; repeat: true
        running: !sock.connected
        onTriggered: { sock.connected = false; Qt.callLater(() => sock.connected = true) }
    }
}
