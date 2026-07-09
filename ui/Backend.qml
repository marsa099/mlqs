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
    property var convs: []
    property string nextCursor: ""
    property string pendingCursor: ""
    property bool loadingConvs: false
    property var messages: []
    property string openConvId: ""
    property string openConvSubject: ""

    signal toast(string text)

    function safeWrite(s) { if (sock.connected) sock.write(s) }
    function send(obj) { safeWrite(JSON.stringify(obj) + "\n") }

    function selectAccount(id) {
        currentAccount = id
        folders = []; convs = []; messages = []
        openConvId = ""; currentFolderId = ""
        send({ type: "folders", account: id })
    }

    function selectFolder(id, name) {
        currentFolderId = id; currentFolderName = name || id
        convs = []; nextCursor = ""; pendingCursor = ""
        openConvId = ""; messages = []
        loadingConvs = true
        send({ type: "conversations", account: currentAccount, folder: id })
    }

    function loadMore() {
        if (nextCursor === "" || loadingConvs) return
        pendingCursor = nextCursor
        loadingConvs = true
        send({ type: "conversations", account: currentAccount, folder: currentFolderId, cursor: nextCursor })
    }

    function openConv(c) {
        if (!c || !c.id) return
        openConvId = c.id
        openConvSubject = c.subject || "(no subject)"
        messages = []
        send({ type: "conversation", account: currentAccount, id: c.id })
        if (c.unread) {
            send({ type: "markread", account: currentAccount, id: c.id })
            markLocalRead(c.id)
        }
    }

    function markLocalRead(id) {
        convs = convs.map(x => x.id === id ? Object.assign({}, x, { unread: false }) : x)
        folders = folders.map(f => f.id === currentFolderId
            ? Object.assign({}, f, { unread: Math.max(0, (f.unread || 0) - 1) }) : f)
    }

    function closeConv() { openConvId = ""; messages = [] }

    function toggleStar(c) {
        if (!c || !c.id) return
        const v = !c.starred
        send({ type: "star", account: currentAccount, id: c.id, text: v ? "true" : "false" })
        convs = convs.map(x => x.id === c.id ? Object.assign({}, x, { starred: v }) : x)
    }

    function archiveConv(id) {
        send({ type: "archive", account: currentAccount, id: id })
        removeLocal(id)
    }

    function trashConv(id) {
        send({ type: "trash", account: currentAccount, id: id })
        removeLocal(id)
    }

    function removeLocal(id) {
        const wasUnread = convs.some(x => x.id === id && x.unread)
        convs = convs.filter(x => x.id !== id)
        if (wasUnread)
            folders = folders.map(f => f.id === currentFolderId
                ? Object.assign({}, f, { unread: Math.max(0, (f.unread || 0) - 1) }) : f)
        if (openConvId === id) closeConv()
    }

    function openHtml(msgId) {
        send({ type: "openhtml", account: currentAccount, id: openConvId, text: msgId })
    }

    function refresh() {
        if (currentFolderId !== "") selectFolder(currentFolderId, currentFolderName)
    }

    function sendMail(d) {
        send({ type: "send", account: currentAccount,
               to: d.to || "", cc: d.cc || "", bcc: d.bcc || "",
               subject: d.subject || "", body: d.body || "",
               replyTo: d.replyTo || "", conv: d.conv || "", paths: d.paths || [] })
    }

    function runSearch(q) {
        if (!q) return
        convs = []; nextCursor = ""; pendingCursor = ""
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
        } else if (e.type === "folders") {
            if (e.account !== currentAccount) return
            folders = (e.folders || []).map(f =>
                Object.assign({}, f, { section: f.role === "label" ? "labels" : "mailbox" }))
            if (currentFolderId === "") {
                const inbox = folders.find(f => f.role === "inbox")
                if (inbox) selectFolder(inbox.id, inbox.name)
            }
        } else if (e.type === "conversations") {
            loadingConvs = false
            if (e.account !== currentAccount) return
            const items = e.items || []
            if (pendingCursor !== "") { convs = convs.concat(items); pendingCursor = "" }
            else convs = items
            nextCursor = e.next || ""
        } else if (e.type === "conversation") {
            if (e.id === openConvId) messages = e.messages || []
        } else if (e.type === "convUpdated") {
            if (e.account !== currentAccount || !e.conv) return
            const c = e.conv
            const inFolder = currentFolderId !== "" && (c.folderIds || []).indexOf(currentFolderId) >= 0
            let list = convs.filter(x => x.id !== c.id)
            if (inFolder) {
                // keep the index date-sorted; new mail lands at the top
                let i = 0
                while (i < list.length && new Date(list[i].date) > new Date(c.date)) i++
                list.splice(i, 0, c)
            }
            convs = list
        } else if (e.type === "convRemoved") {
            if (e.account !== currentAccount) return
            convs = convs.filter(x => x.id !== e.id)
            if (openConvId === e.id) closeConv()
        } else if (e.type === "sent") {
            toast("sent ✓")
        } else if (e.type === "toast") {
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
                if (currentFolderId !== "")
                    send({ type: "conversations", account: currentAccount, folder: currentFolderId })
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
