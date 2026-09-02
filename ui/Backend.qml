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

    // ── unified inbox ──────────────────────────────────────────────────────
    // The resting view is every account's inbox merged. Picking an account is a
    // FILTER on that (and, since only the inbox is unified, also the scope that
    // gives you its Sent/Starred/Trash): "" = all accounts.
    property string accountFilter: ""
    readonly property bool unified: currentFolderId === "__all"
    readonly property bool threadsView: currentFolderId === "__threads"
    readonly property bool searchView: currentFolderId === "__search"
    // Any view whose rows can come from more than one mailbox: the merged inbox,
    // Filtered, Threads or search results with no account filter. Here identity is
    // (account, tid) — a tid alone collides across accounts, and acting on the
    // collision archives/stars the wrong mailbox's row — and rows carry an account
    // chip. Distinct from `unified`, which means the merged INBOX specifically.
    readonly property bool merged: accountFilter === ""
                                   && (unified || filteredView || threadsView || searchView)
    // every account's folder list, not just the current one — each provider names
    // its inbox differently (Gmail "INBOX", IMAP "INBOX", Graph an opaque id), so
    // the merged fetch has to look the id up per account
    property var foldersByAccount: ({})
    property var _convsByAccount: ({})   // account -> [conv] (raw, pre-merge)
    property var cursorByAccount: ({})   // account -> next cursor ("" = exhausted)
    property var _pagingAccounts: ({})   // account -> true while a page is in flight
    property var acctError: ({})         // account -> true when its fetch failed
    // The chosen inbox survives a restart: someone who focused their personal
    // mailbox should not be dropped back into All accounts on every launch.
    // Boot is a race — the saved value and the workspaces event arrive in either
    // order — so whichever lands second applies the view exactly once.
    property bool _viewLoaded: false
    property bool _viewApplied: false
    property string _savedFilter: ""
    FileView {
        id: viewStore
        path: Quickshell.env("HOME") + "/.cache/mlqs/view.json"
        onLoaded: {
            try { backend._savedFilter = (JSON.parse(text()) || {}).filter || "" } catch (e) { }
            backend._viewLoaded = true
            backend._applyBootView()
        }
        onLoadFailed: { backend._viewLoaded = true; backend._applyBootView() }   // first run: no file yet
    }
    function _saveView() {
        viewStore.setText(JSON.stringify({ filter: accountFilter }))
    }
    function _applyBootView() {
        if (_viewApplied || !_viewLoaded || workspaces.length === 0) return
        _viewApplied = true
        // an account that no longer exists falls back to the merged inbox
        const known = workspaces.some(w => w.id === _savedFilter)
        if (_savedFilter !== "" && known) selectAccount(_savedFilter)
        else selectUnified()
    }

    function _inboxIdFor(acct) {
        const f = (foldersByAccount[acct] || []).find(f => f.role === "inbox")
        return f ? f.id : ""
    }
    // ListModel, not a JS array: in-place setProperty/insert/remove keep the
    // ListView's delegates and cursor alive (array replacement rebuilds all
    // rows — the cursor "blink" on every read/star toggle)
    readonly property var convs: convsModel
    ListModel { id: convsModel }
    property string nextCursor: ""
    property string pendingCursor: ""
    property bool loadingConvs: false
    // folder id whose authoritative (live) page has landed — gates the cached
    // warm-paint so it can't clobber fresh data mid-load
    property string _freshFolder: ""
    property var messages: []
    property string openConvId: ""
    property string openConvSubject: ""

    // flat display row for the ListModel (nested arrays don't survive it)
    // Gmail digests label changes lazily: a sync tick in the gap after
    // markread still reports UNREAD (same race the daemon dodges for folder
    // counts) and would re-bold a row we just read — with nothing after to
    // correct it. Recently-read threads hold their local read state.
    property var readGrace: ({})

    // account|id, because conversation ids are only unique WITHIN a provider —
    // Gmail thread ids, Graph conversation ids and IMAP's base64(folder|uidvalidity|
    // rootUID) are separate spaces, so a bare id can collide in a merged list
    function rowKey(acct, id) { return (acct || "") + "|" + id }

    function toRow(c, acct) {
        const a = acct || currentAccount
        const graced = (Date.now() - (readGrace[rowKey(a, c.id)] || 0)) < 90000
        // the LAST sender, matching what notifications already call "who". `who`
        // below is a display string (truncated, "+N", "(3)" suffix) and cannot be
        // used to author a rule or to tell a bot apart from the address it mails via.
        const sndrs = c.senders || []
        const last = sndrs.length ? sndrs[sndrs.length - 1] : {}
        return {
            tid: c.id, account: a, subject: c.subject || "", snippet: c.snippet || "",
            senderEmail: last.email || "", senderName: last.name || "",
            who: senderLine(c) + ((c.msgCount || 1) > 1 ? " (" + c.msgCount + ")" : ""),
            dateStr: fmtDate(c.date), dateMs: new Date(c.date).getTime(),
            unread: !!c.unread && !graced, starred: !!c.starred
        }
    }
    // acct omitted → match on id alone (single-account views, where it's unique)
    function findRow(id, acct) {
        for (let i = 0; i < convsModel.count; i++) {
            const r = convsModel.get(i)
            if (r.tid === id && (acct === undefined || r.account === acct)) return i
        }
        return -1
    }

    // ── filter rules ───────────────────────────────────────────────────────
    // The daemon owns matching (it also suppresses notifications); the UI owns
    // authoring. It sends the whole replacement list, so the two can't desync.
    property var rules: []
    signal ruleCandidates(var cands, string note)
    function saveRules(list) { send({ type: "rulesSave", rules: list || [] }) }
    function addRule(r) {
        const id = "r" + Date.now() + Math.floor(Math.random() * 1000)
        saveRules((rules || []).concat([Object.assign({ id: id }, r)]))
    }
    function deleteRule(id) { saveRules((rules || []).filter(r => r.id !== id)) }

    // Ask the daemon's model what a selection has in common. The obvious candidates
    // are computed locally too (localCandidates), so this still works for someone
    // with no AI provider configured.
    function suggestRules(rows) {
        const items = (rows || []).map(r => ({
            senderEmail: r.senderEmail || "", senderName: r.senderName || "", subject: r.subject || ""
        }))
        if (!items.length) return
        send({ type: "rulesuggest", items: items })
    }

    // ListModel rows (convsModel.get(i)) are transient ModelObjects: reading their
    // properties inside a BINDING makes QML capture a dependency on them, and the
    // notifier dangles the moment the model changes — a segfault, not a warning.
    // Everything below therefore works on plain JS copies, taken imperatively.
    function plainRow(r) {
        return r ? { tid: r.tid, account: r.account, subject: r.subject || "",
                     senderEmail: r.senderEmail || "", senderName: r.senderName || "",
                     who: r.who || "", unread: !!r.unread } : null
    }
    function plainRows(rows) {
        const out = []
        for (const r of (rows || [])) { const p = plainRow(r); if (p) out.push(p) }
        return out
    }
    function visibleRows() {
        const out = []
        for (let i = 0; i < convsModel.count; i++) out.push(plainRow(convsModel.get(i)))
        return out
    }

    // Deterministic "common denominator": whatever every selected row shares.
    // This is what makes the GitHub case work without a model — the shared address
    // and the shared name are both exact, and the pair is the tight rule.
    function localCandidates(rows) {
        if (!rows || !rows.length) return []
        const allSame = f => rows.every(r => (r[f] || "") === (rows[0][f] || "")) ? (rows[0][f] || "") : ""
        const email = allSame("senderEmail"), name = allSame("senderName")
        const out = []
        if (email && name) out.push({ label: "this sender AND name", senderEmail: email, senderName: name, exact: true })
        if (email) out.push({ label: "anything from " + email, senderEmail: email, exact: true })
        if (name) out.push({ label: "anyone named " + name, senderName: name, exact: true })
        // a shared subject prefix, when it's long enough to be meaningful
        const subs = rows.map(r => r.subject || "")
        let pre = subs[0]
        for (const t of subs) { let i = 0; while (i < pre.length && i < t.length && pre[i] === t[i]) i++; pre = pre.slice(0, i) }
        pre = pre.trim()
        if (pre.length >= 8) out.push({ label: 'subject starts "' + pre + '"', subject: pre })
        return out
    }

    // How much would this candidate hide? Answered locally and instantly: that is
    // the difference between hiding one bot and hiding all of GitHub.
    // Pure over plain arrays — never called from a binding, and never touches the
    // ListModel (see plainRow above).
    function candidateReach(c, rows, view) {
        const m = r => {
            if (!c.senderEmail && !c.senderName && !c.subject) return false
            const f = (want, got) => !want || (c.exact
                ? (got || "").toLowerCase() === want.toLowerCase()
                : (got || "").toLowerCase().indexOf(want.toLowerCase()) >= 0)
            return f(c.senderEmail, r.senderEmail) && f(c.senderName, r.senderName) && f(c.subject, r.subject)
        }
        let inSel = 0
        for (const r of (rows || [])) if (m(r)) inSel++
        let inView = 0
        for (const r of (view || [])) if (m(r)) inView++
        return { sel: inSel, selTotal: (rows || []).length, view: inView }
    }

    // Attach reach to each candidate ONCE, imperatively, so the delegate reads a
    // plain value instead of re-evaluating a binding against the live model.
    function withReach(cands, rows) {
        const view = visibleRows()
        const out = []
        for (const c of (cands || [])) out.push(Object.assign({}, c, { reach: candidateReach(c, rows, view) }))
        return out
    }

    // inbox unread per account (tab badges for the non-active accounts)
    property var accountUnread: ({})

    signal toast(string text)
    signal summonRequested()
    signal dismissRequested()
    signal contactsResult(var items, string query)
    function queryContacts(q) { send({ type: "contacts", account: currentAccount, query: q }) }

    // All → each account → All. "" (all) is a first-class stop in the cycle, so
    // ⌃⇧L/H walks the same list the ⌃S dropdown shows.
    // Changing the SCOPE keeps the view you're in: from Threads you get that
    // account's threads, not its inbox. A folder jump (gu, the sidebar's All row)
    // is a different intent and still lands on the merged inbox.
    function setFilter(id) {
        const keep = threadsView
        if (id === "") selectUnified(); else selectAccount(id)
        if (keep) selectThreads()
    }

    function cycleAccount(d) {
        if (workspaces.length < 1) return
        const ids = [""].concat(workspaces.map(w => w.id))
        const n = ids.length
        const i = ids.indexOf(accountFilter)
        const next = ids[((i < 0 ? 0 : i) + (d || 1) + n) % n]
        setFilter(next)
    }

    function safeWrite(s) { if (sock && sock.connected) sock.write(s) }
    function send(obj) { safeWrite(JSON.stringify(obj) + "\n") }

    // ⌃⇧r: force an update check now; the daemon toasts the result.
    function checkForUpdates() { toast("Checking for updates…"); send({ type: "checkupdate" }) }

    // copy feedback is visual (row flash + bar morph, slqs grammar) — no toast
    property double copyPulse: 0
    function copyToClipboard(t) {
        if (!t || !t.length) { toast("nothing to copy"); return }
        Quickshell.execDetached(["wl-copy", "--", t])
        copyPulse = Date.now()
    }

    // ── Summaries (ported from dsqrd) ──────────────────────────────────────
    property string summaryText: ""
    property bool   summaryLoading: false
    property var    summarizeClis: []        // logged-in CLIs the setup guide offers
    property string summaryScope: ""         // thread | message | inbox (for the modal)
    property var    summaryIds: []           // inbox: the unread ids, for mark-all-read
    property var    summaryQA: []            // conversational follow-ups: [{q, a}]
    property bool   summaryAsking: false     // a follow-up question is in flight
    property string summaryFraming: ""       // the user's framing for a custom summary (title)
    property var    _askCtx: ({})            // {scope,id,conv,folder} of the current summary
    signal summaryReady()
    signal summarizeSetupNeeded()
    signal summarizePromptNeeded(string meta)   // open the modal's framing input

    // scope: "thread" (id=convId) | "message" (id=msgId, conv=convId) | "inbox"
    // (uses the focused folder). One in-flight at a time.
    // Trigger the summary flow: open the modal on a framing input (↵ = default
    // recap, or type a framing like "action points"). Doesn't call the model yet.
    function summarize(scope, id, conv) {
        if (summaryLoading) return
        _askCtx = { scope: scope, id: id || "", conv: conv || "", folder: currentFolderId, ids: [] }
        summaryText = ""; summaryFraming = ""; summaryQA = []; summaryScope = scope; summaryIds = []
        summarizePromptNeeded(scope === "inbox" ? currentFolderName : openConvSubject)
    }
    // Summarize/ask about a visual-mode selection of conversations.
    function summarizeSelection(ids) {
        if (summaryLoading || !ids || !ids.length) return
        _askCtx = { scope: "selection", id: "", conv: "", folder: currentFolderId, ids: ids }
        summaryText = ""; summaryFraming = ""; summaryQA = []; summaryScope = "selection"; summaryIds = ids
        summarizePromptNeeded(ids.length + " selected")
    }
    // Run the initial summary — empty framing → default recap, else a framed one.
    function summarizeRun(framing) {
        if (summaryLoading) return
        summaryLoading = true
        summaryFraming = ("" + (framing || "")).trim()
        summaryTimeout.restart()
        send({ type: "summarize", account: currentAccount, scope: _askCtx.scope,
               id: _askCtx.id, conv: _askCtx.conv, folder: _askCtx.folder, ids: _askCtx.ids || [],
               question: summaryFraming, followup: false })
    }
    // Ask a free-text question about the current summary's content — reuses the
    // same scope/id so the daemon rebuilds the identical transcript.
    function summarizeAsk(question) {
        const q = ("" + (question || "")).trim()
        if (!q || summaryAsking || !_askCtx.scope) return
        summaryAsking = true
        summaryQA = summaryQA.concat([{ q: q, a: "" }])
        summaryTimeout.restart()
        send({ type: "summarize", account: currentAccount, scope: _askCtx.scope,
               id: _askCtx.id, conv: _askCtx.conv, folder: _askCtx.folder, ids: _askCtx.ids || [], question: q, followup: true })
    }
    function summarizeEnableCli(cliId) { send({ type: "summarizeEnable", provider: cliId }) }
    function summarizeEnableKey(provider, key) { send({ type: "summarizeEnable", provider: provider, api_key: key || "" }) }
    // Mark every summarized unread conversation read, reusing the markread path.
    function markAllRead(ids) {
        if (!ids || !ids.length) return
        for (const id of ids) {
            const i = findRow(id)
            const acct = i >= 0 ? (convsModel.get(i).account || currentAccount) : currentAccount
            send({ type: "markread", account: acct, id: id, text: "true" })
            setLocalRead(id, true, acct)
        }
    }

    // ⇧R: mark every unread conversation in the view read. Scoped to what is on
    // screen, so unfiltered it spans all accounts and filtered it is just that one.
    // Routes per row, so each markread reaches its owning mailbox.
    function markViewRead() {
        const rows = []
        for (let i = 0; i < convsModel.count; i++) {
            const r = convsModel.get(i)
            if (r.unread) rows.push({ tid: r.tid, account: r.account })
        }
        if (rows.length === 0) { toast("nothing unread here"); return }
        for (const r of rows) {
            send({ type: "markread", account: r.account || currentAccount, id: r.tid, text: "true" })
            setLocalRead(r.tid, true, r.account)
        }
        toast("marked " + rows.length + " read")
    }

    // Safety net: if the daemon never replies (hung provider), drop the spinner.
    Timer {
        id: summaryTimeout; interval: 210000; repeat: false
        onTriggered: {
            if (backend.summaryLoading || backend.summaryAsking) {
                backend.summaryLoading = false; backend.summaryAsking = false
                backend.toast("Summarize timed out")
            }
        }
    }

    // rich yank: file:// imgs become base64 data URIs so a paste into a
    // rich editor (gmail, slack) carries the images along
    readonly property string _inlineImgsPy:
        "import sys,base64,re,mimetypes\n" +
        "h=sys.stdin.read()\n" +
        "def r(m):\n" +
        "    p=m.group(1)\n" +
        "    mt=mimetypes.guess_type(p)[0] or 'image/png'\n" +
        "    try: d=base64.b64encode(open(p,'rb').read()).decode()\n" +
        "    except Exception: return m.group(0)\n" +
        "    return 'src=\"data:'+mt+';base64,'+d+'\"'\n" +
        "sys.stdout.write(re.sub(r'src=\"file://([^\"]+)\"', r, h))\n"
    function copyRichToClipboard(html) {
        if (!html || !html.length) { toast("nothing to copy"); return }
        Quickshell.execDetached(["setsid", "-f", "sh", "-c",
            'printf %s "$1" | python3 -c "$2" | wl-copy -t text/html', "_",
            html, _inlineImgsPy])
        copyPulse = Date.now()
    }

    function copyImageToClipboard(src) {
        let path = src
        if (path.indexOf("file://") === 0) path = path.slice(7)
        // always offer PNG: clipse (history) classifies images by PNG magic
        // bytes, and png pastes everywhere — magick converts the rest
        const ext = path.split(".").pop().toLowerCase()
        const cmd = ext === "png"
            ? 'wl-copy -t image/png < "' + path + '"'
            : 'magick "' + path + '" png:- | wl-copy -t image/png'
        Quickshell.execDetached(["setsid", "-f", "sh", "-c", cmd])
        copyPulse = Date.now()
    }

    function selectAccount(id) {
        accountFilter = id
        _saveView()
        currentAccount = id
        // keep the stale folder list rendered until the new one lands —
        // blanking it collapses the sidebar for a frame (the account-switch jump)
        convsModel.clear(); messages = []
        openConvId = ""; currentFolderId = ""
        // calendars are per-account: a stale list makes the event composer
        // offer (and target) the previous account's calendars
        accountCalendars = []
        send({ type: "folders", account: id })
    }

    // The merged inbox: every account's inbox in one list. Accounts whose folder
    // list hasn't landed yet get a `folders` request; the folders handler kicks
    // off their fetch when it arrives, so a cold start fills in as replies come.
    function selectUnified() {
        accountFilter = ""
        _saveView()
        currentFolderId = "__all"; currentFolderName = "All accounts"
        openConvId = ""; messages = []
        convsModel.clear()
        nextCursor = ""; pendingCursor = ""
        _convsByAccount = {}; cursorByAccount = {}; _pagingAccounts = {}; acctError = {}
        loadingConvs = true
        for (const w of workspaces) {
            if (_inboxIdFor(w.id) !== "") _fetchUnifiedFor(w.id)
            else send({ type: "folders", account: w.id })
        }
    }

    function _fetchUnifiedFor(acct) {
        const inbox = _inboxIdFor(acct)
        if (inbox === "") return
        send({ type: "conversations", account: acct, folder: inbox })
    }

    // Merge every account's rows into one list. The inbox and Filtered put the
    // unread block first (the ordering invariant convUpdated's reinsertion relies
    // on), date-desc within each block; Threads and search results are chronologies,
    // so they sort on date alone — safe because convUpdated bails out in both.
    function _rebuildMerged() {
        const all = []
        for (const acct in _convsByAccount)
            for (const c of _convsByAccount[acct]) all.push(toRow(c, acct))
        all.sort((threadsView || searchView)
            ? ((a, b) => b.dateMs - a.dateMs)
            : ((a, b) => (a.unread === b.unread) ? (b.dateMs - a.dateMs) : (a.unread ? -1 : 1)))
        convsModel.clear()
        const seen = {}
        for (const r of all) {
            const k = rowKey(r.account, r.tid)
            if (seen[k]) continue
            seen[k] = true
            convsModel.append(r)
        }
    }

    // single-key folder jumps (i inbox, s sent, …). Unfiltered, "inbox" means the
    // merged one — otherwise it'd silently drop you into one account.
    function jumpRole(role) {
        if (role === "inbox" && accountFilter === "") { selectUnified(); return }
        const f = folders.find(f => f.role === role)
        if (f) selectFolder(f.id, f.name)
    }

    // Filtered: everything the rules hid, served from the daemon's cache (which
    // holds unfiltered truth because every write happens before its emit). Same
    // fan-out shape as the merged inbox when unfiltered.
    readonly property bool filteredView: currentFolderId === "__filtered"
    function selectFiltered() {
        currentFolderId = "__filtered"; currentFolderName = "Filtered"
        openConvId = ""; messages = []
        convsModel.clear(); nextCursor = ""; pendingCursor = ""
        _convsByAccount = {}
        loadingConvs = true
        const accts = accountFilter === "" ? workspaces.map(w => w.id) : [accountFilter]
        for (const a of accts) send({ type: "filtered", account: a })
    }

    // Threads follows the account scope, same fan-out as Filtered: every mailbox
    // when unfiltered, one when filtered. Each account answers separately and the
    // rebuild merges them.
    function selectThreads() {
        currentFolderId = "__threads"; currentFolderName = "Threads"
        convsModel.clear(); nextCursor = ""; pendingCursor = ""
        openConvId = ""; messages = []
        _convsByAccount = {}
        loadingConvs = true
        const accts = accountFilter === "" ? workspaces.map(w => w.id) : [accountFilter]
        for (const a of accts) send({ type: "threads", account: a })
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
        if (id === "__all") { selectUnified(); return }
        if (id === "__filtered") { selectFiltered(); return }
        openConvId = ""; messages = []
        _loadFolder(id, name)
    }

    function loadMore() {
        // Threads and search results are whole answers, not pages: provider.Search
        // takes no cursor, so there is nothing to ask for. Firing the folder request
        // below with their sentinel id is what used to garble a long result list.
        if (threadsView || searchView) return
        if (unified) {
            // page every account that still has mail; each keeps its own cursor
            // (three unrelated formats server-side, so they can't be combined)
            for (const acct in cursorByAccount) {
                if (cursorByAccount[acct] === "" || _pagingAccounts[acct]) continue
                const p = Object.assign({}, _pagingAccounts); p[acct] = true; _pagingAccounts = p
                send({ type: "conversations", account: acct,
                       folder: _inboxIdFor(acct), cursor: cursorByAccount[acct] })
            }
            return
        }
        if (nextCursor === "" || loadingConvs) return
        pendingCursor = nextCursor
        loadingConvs = true
        send({ type: "conversations", account: currentAccount, folder: currentFolderId, cursor: nextCursor })
    }

    // mark-read is deferred until the conversation payload arrives — sent
    // eagerly it races the fetch and the per-message "new" flags come back
    // already cleared
    property string pendingRead: ""

    // the open conversation's owning account — reply/attachment/RSVP identity comes
    // from HERE, not currentAccount, or a reply from a merged list sends from the
    // wrong mailbox
    property string openConvAccount: ""

    function openConv(row) {
        if (!row || !row.tid) return
        const acct = row.account || currentAccount
        openConvId = row.tid
        openConvAccount = acct
        openConvSubject = row.subject || "(no subject)"
        messages = []
        pendingRead = row.unread ? row.tid : ""
        send({ type: "conversation", account: acct, id: row.tid })
    }

    // Adjust one (account, folder) unread count. The account is explicit because
    // reading a `work` row in the merged list must not decrement whichever
    // account happened to be selected. accountUnread — the per-account inbox
    // tally behind the account-pill and All-accounts badges — is kept in step
    // whenever the touched folder IS that account's inbox. Callers must go
    // through here: patching `folders` alone left accountUnread stale until the
    // next `folders` event, so the badges kept advertising already-read mail.
    function _bumpFolderUnread(acct, fid, delta) {
        if (fid !== "") {
            const fm = Object.assign({}, foldersByAccount)
            fm[acct] = (fm[acct] || []).map(f => f.id === fid
                ? Object.assign({}, f, { unread: Math.max(0, (f.unread || 0) + delta) }) : f)
            foldersByAccount = fm
            if (acct === currentAccount)
                folders = folders.map(f => f.id === fid
                    ? Object.assign({}, f, { unread: Math.max(0, (f.unread || 0) + delta) }) : f)
        }
        if (fid === _inboxIdFor(acct)) {
            const am = Object.assign({}, accountUnread)
            am[acct] = Math.max(0, (am[acct] || 0) + delta)
            accountUnread = am
        }
    }

    // The folder the given account's rows live in right now: the merged view
    // spans every account's inbox, an inline view is just the open folder.
    function _activeFolderFor(acct) {
        return unified ? _inboxIdFor(acct) : currentFolderId
    }

    function setLocalRead(id, read, acct) {
        const a = acct || openConvAccount || currentAccount
        const k = rowKey(a, id)
        if (read) readGrace[k] = Date.now()
        else delete readGrace[k]
        const i = findRow(id, merged ? a : undefined)
        if (i >= 0) convsModel.setProperty(i, "unread", !read)
        _bumpFolderUnread(a, _activeFolderFor(a), read ? -1 : 1)
    }

    // Shift+R in the index: flip a thread's read state (server + local)
    function toggleRead(row) {
        if (!row || !row.tid) return
        const acct = row.account || currentAccount
        const read = !!row.unread   // unread → mark read; read → mark unread
        send({ type: "markread", account: acct, id: row.tid, text: read ? "true" : "false" })
        setLocalRead(row.tid, read, acct)
    }

    function closeConv() { openConvId = ""; openConvAccount = ""; messages = [] }

    function toggleStar(row) {
        if (!row || !row.tid) return
        const acct = row.account || currentAccount
        const v = !row.starred
        send({ type: "star", account: acct, id: row.tid, text: v ? "true" : "false" })
        const i = findRow(row.tid, merged ? acct : undefined)
        if (i >= 0) convsModel.setProperty(i, "starred", v)
    }

    // one-level undo for destructive moves (u) — Gmail restores server-side.
    // Holds a LIST so visual-mode batches undo as one unit.
    property var lastRemoved: null

    function _snapRow(i) {
        const r = convsModel.get(i)
        return { idx: i, row: { tid: r.tid, account: r.account, subject: r.subject, snippet: r.snippet,
                                who: r.who, senderEmail: r.senderEmail, senderName: r.senderName,
                                dateStr: r.dateStr, dateMs: r.dateMs,
                                unread: r.unread, starred: r.starred } }
    }

    // rows, not ids: a merged selection can span accounts, so each item has to
    // carry its own mailbox through the move and the undo
    function _removeMany(kind, rows) {
        const items = []
        for (const r of rows || []) {
            if (!r || !r.tid) continue
            const i = findRow(r.tid, merged ? (r.account || currentAccount) : undefined)
            if (i >= 0) items.push(_snapRow(i))
        }
        if (items.length === 0) return 0
        lastRemoved = { kind: kind, folderId: currentFolderId, items: items }
        for (const it of items) {
            const acct = it.row.account || currentAccount
            send({ type: kind, account: acct, id: it.row.tid })
            removeLocal(it.row.tid, acct)
        }
        return items.length
    }

    function archiveConv(row) {
        if (_removeMany("archive", [row])) toast("archived — u undoes")
    }
    function trashConv(row) {
        if (_removeMany("trash", [row])) toast("trashed — u undoes")
    }
    function batchArchive(rows) {
        const n = _removeMany("archive", rows)
        if (n) toast(n + " archived — u undoes")
    }
    function batchTrash(rows) {
        const n = _removeMany("trash", rows)
        if (n) toast(n + " trashed — u undoes")
    }
    // rows: model rows; if any unread → all read, else all unread
    function batchRead(rows) {
        if (!rows.length) return
        const read = rows.some(r => r.unread)
        for (const r of rows) {
            if (!!r.unread !== read) continue
            const acct = r.account || currentAccount
            send({ type: "markread", account: acct, id: r.tid, text: read ? "true" : "false" })
            setLocalRead(r.tid, read, acct)
        }
        toast(read ? "marked read" : "marked unread")
    }
    function batchStar(rows) {
        if (!rows.length) return
        const star = rows.some(r => !r.starred)
        for (const r of rows) {
            if (!!r.starred === star) continue
            const acct = r.account || currentAccount
            send({ type: "star", account: acct, id: r.tid, text: star ? "true" : "false" })
            const i = findRow(r.tid, merged ? acct : undefined)
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
            const acct = it.row.account || currentAccount
            send({ type: verb, account: acct, id: it.row.tid })
            // re-render only where the row belongs: the merged list takes every
            // account back, a filtered one only its own
            const visible = lr.folderId === currentFolderId && (merged || acct === currentAccount)
            if (visible) {
                convsModel.insert(Math.min(it.idx, convsModel.count), it.row)
                if (it.row.unread) _bumpFolderUnread(acct, _activeFolderFor(acct), 1)
            }
        }
        toast((items.length > 1 ? items.length + " " : "") + (lr.kind === "trash" ? "restored from trash" : "restored to inbox"))
    }

    function removeLocal(id, acct) {
        const a = acct || currentAccount
        const i = findRow(id, merged ? a : undefined)
        if (i >= 0) {
            if (convsModel.get(i).unread) _bumpFolderUnread(a, _activeFolderFor(a), -1)
            convsModel.remove(i)
        }
        // drop the raw row too, or the next merge rebuild resurrects it
        if (_convsByAccount[a]) {
            const m = Object.assign({}, _convsByAccount)
            m[a] = m[a].filter(c => c.id !== id)
            _convsByAccount = m
        }
        if (openConvId === id) closeConv()
    }

    function openAttachment(msgId, att) {
        if (!att) return
        send({ type: "openatt", account: openConvAccount || currentAccount, id: msgId,
               text: att.id || "", query: att.contentId || "", folder: att.name || "" })
    }

    function openHtml(msgId) {
        send({ type: "openhtml", account: openConvAccount || currentAccount, id: openConvId, text: msgId })
    }

    function refresh() {
        if (unified) { selectUnified(); return }
        if (searchView) { runSearch(searchQuery); return }   // re-run it; keeps _preSearch*
        if (currentFolderId !== "") selectFolder(currentFolderId, currentFolderName)
    }

    // optimistic echo: a sent reply appears in the open conversation
    // immediately (chat-client behavior), not after the next sync
    function appendLocalMessage(d) {
        if (openConvId === "") return
        const me = workspaces.find(w => w.id === (openConvAccount || currentAccount)) || {}
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
        // a reply/forward sends from the conversation's own mailbox; d.account lets
        // a fresh compose name one explicitly
        send({ type: "send", account: d.account || openConvAccount || currentAccount,
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
    property var _calendarTarget: null
    signal calendarEventTargeted(int index)

    function selectCalendar() {
        _calendarTarget = null
        currentFolderId = "__calendar"; currentFolderName = "Calendar"
        openConvId = ""; messages = []
        calFilter = 0   // fresh entry always shows everything
        refreshAgenda()
    }
    function showMeetingInCalendar(meeting, account) {
        if (!meeting) return
        // widen the span first so the refresh can actually reach the event —
        // past the month chip the span goes bespoke (no chip lights up)
        const start = new Date(meeting.start)
        const days = Math.ceil((start.getTime() - Date.now()) / 86400000) + 1
        if (days > agendaDays) agendaDays = days <= 7 ? 7 : days <= 31 ? 31 : days
        selectCalendar()
        _calendarTarget = {   // after selectCalendar, which resets it
            eventId: meeting.eventId || "",
            iCalUid: meeting.iCalUid || "",
            account: account || openConvAccount || currentAccount
        }
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
        for (const w of workspaces) {
            if (w.calendar === false) continue
            send({ type: "agenda", account: w.id, text: String(agendaDays) })
            send({ type: "calendars", account: w.id })   // names for the filter chips
        }
    }

    // calendar filter: 0 = all (default), else 1-based index into calFilterList
    property int calFilter: 0
    property var calFilterList: []          // [{key, label, hidden}] — calendars present in the agenda
    property var _calsByAccount: ({})       // account -> [{id, name, primary, …}]
    function cycleCalFilter(d) {
        const n = calFilterList.length
        if (n === 0) return
        calFilter = (calFilter + (d || 1) + n + 1) % (n + 1)
        _rebuildAgenda()
    }

    // locally hidden calendars (auto-subscribed week-number/holiday feeds):
    // dropped from the merged agenda, still cyclable so x can unhide them.
    // Persisted in the cache dir — the daemon already guarantees it exists.
    property var hiddenCals: ({})
    FileView {
        id: hiddenCalStore
        path: Quickshell.env("HOME") + "/.cache/mlqs/hidden-cals.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { backend.hiddenCals = JSON.parse(text()) } catch (e) { return }
            if (backend.currentFolderId === "__calendar") backend._rebuildAgenda()
        }
    }
    function toggleHideCal() {
        if (calFilter <= 0 || calFilter > calFilterList.length) return
        const f = calFilterList[calFilter - 1]
        const h = Object.assign({}, hiddenCals)
        if (h[f.key]) delete h[f.key]; else h[f.key] = true
        hiddenCals = h
        hiddenCalStore.setText(JSON.stringify(h))
        toast((h[f.key] ? "hidden: " : "shown: ") + f.label)
        _rebuildAgenda()
    }
    function _calLabel(acct, calId) {
        const c = (_calsByAccount[acct] || []).find(c => c.id === calId)
        return c && !c.primary ? acct + " · " + c.name : acct
    }
    function _rebuildAgenda() {
        eventsModel.clear()
        let all = []
        for (const acct in _agendaByAccount)
            for (const ev of _agendaByAccount[acct]) all.push(Object.assign({ account: acct }, ev))
        all.sort((a, b) => new Date(a.start) - new Date(b.start))
        // filter chips: every subscribed calendar — not just those with events
        // in the loaded span, else sparse calendars silently vanish from the
        // cycle and can't be inspected or unhidden. Events whose calendar the
        // list doesn't know yet (reply still in flight) are unioned in.
        const fseen = {}, flist = []
        const addChip = (acct, calId) => {
            const k = acct + "|" + calId
            if (fseen[k]) return
            fseen[k] = true
            flist.push({ key: k, label: _calLabel(acct, calId), hidden: !!hiddenCals[k] })
        }
        for (const acct in _calsByAccount)
            for (const c of _calsByAccount[acct]) addChip(acct, c.id)
        for (const ev of all) addChip(ev.account, ev.calId)
        flist.sort((a, b) => a.label.localeCompare(b.label))
        calFilterList = flist
        if (calFilter > flist.length) calFilter = 0
        const act = calFilter > 0 ? flist[calFilter - 1].key : ""
        // the same event often exists on both accounts' calendars — collapse,
        // preferring the copy that carries my RSVP status. Filter first, so
        // picking a calendar shows ITS copy of a cross-account event.
        const seen = {}, out = []
        for (const ev of all) {
            const ck = ev.account + "|" + ev.calId
            // "all" drops hidden calendars; a direct filter still shows them
            if (act ? ck !== act : hiddenCals[ck]) continue
            const k = (ev.iCalUid || ev.id) + "|" + ev.start
            if (seen[k] === undefined) { seen[k] = out.length; out.push(ev) }
            else if (!out[seen[k]].myStatus && ev.myStatus) out[seen[k]] = ev
        }
        for (const ev of out) eventsModel.append(toEventRow(ev))
        if (_calendarTarget) {
            for (let i = 0; i < eventsModel.count; i++) {
                const row = eventsModel.get(i)
                const idMatch = _calendarTarget.eventId !== "" && row.eid === _calendarTarget.eventId
                const uidMatch = _calendarTarget.iCalUid !== "" && row.iCalUid === _calendarTarget.iCalUid
                if ((idMatch || uidMatch) && (!_calendarTarget.account || row.account === _calendarTarget.account)) {
                    _calendarTarget = null
                    calendarEventTargeted(i)
                    break
                }
            }
        }
    }
    function toEventRow(ev) {
        const s = new Date(ev.start), e = new Date(ev.end)
        return {
            eid: ev.id, iCalUid: ev.iCalUid || "", calId: ev.calId, account: ev.account,
            title: ev.title || "(untitled)", location: ev.location || "",
            startMs: s.getTime(), dayKey: dayKey(s),
            timeStr: ev.allDay ? "all day" : Qt.formatTime(s, "hh:mm") + "–" + Qt.formatTime(e, "hh:mm"),
            allDay: !!ev.allDay, meetLink: ev.meetLink || "", htmlLink: ev.htmlLink || "",
            myStatus: ev.myStatus || "", organizer: ev.organizer || "",
            attendeeCount: (ev.attendees || []).length,
            description: ev.description || "",
            attendeesJson: JSON.stringify(ev.attendees || [])
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
    function rsvpMail(msgId, status, eventId) {
        send({ type: "rsvpmail", account: openConvAccount || currentAccount, conv: openConvId,
               id: msgId, event: eventId || "", text: status })
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

    // The view a search interrupted, so Esc can put it back. Captured once: running a
    // second search from within a result list must still return to where you started.
    property string searchQuery: ""
    property string _preSearchId: ""
    property string _preSearchName: ""

    // Search follows the account scope, same fan-out as Threads. It is a real view
    // (`__search`), not the empty id that also means "nothing loaded yet" — refresh
    // and paging both key off having an id.
    function runSearch(q) {
        if (!q) return
        if (!searchView) { _preSearchId = currentFolderId; _preSearchName = currentFolderName }
        searchQuery = q
        currentFolderId = "__search"; currentFolderName = "search: " + q
        openConvId = ""; messages = []
        convsModel.clear(); nextCursor = ""; pendingCursor = ""
        _convsByAccount = {}
        loadingConvs = true
        const accts = accountFilter === "" ? workspaces.map(w => w.id) : [accountFilter]
        for (const a of accts) send({ type: "search", account: a, query: q })
    }

    // Leave the search entirely — results gone, previous view restored. A search
    // started before anything had loaded falls back to the merged inbox.
    function exitSearch() {
        if (!searchView) return
        const id = _preSearchId, name = _preSearchName
        searchQuery = ""; _preSearchId = ""; _preSearchName = ""
        if (id === "" || id === "__all") { selectUnified(); return }
        if (id === "__calendar") { selectCalendar(); return }
        selectFolder(id, name)
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

    property bool updateAvailable: false
    property string updateCurrent: ""
    property string updateLatest: ""
    property var updateChangelog: []   // "What's new" entries between current→latest
    // Shift+U → run the host's apply command (parity with slqs/dsqrd). Detect-only:
    // the app never self-updates; SLK_UPDATE_CMD is the host's apply step (bump the
    // flake + rebuild + restart). Runs via `sh -c` so it can spawn its own terminal
    // for sudo. Toasts if unset — nothing on this machine sets it yet.
    function applyUpdate() {
        const cmd = Quickshell.env("SLK_UPDATE_CMD")
        if (cmd && cmd.length > 0) Quickshell.execDetached(["sh", "-c", cmd])
        else toast("No update command set — configure SLK_UPDATE_CMD")
    }

    function onEvent(line) {
        let e
        try { e = JSON.parse(line) } catch (err) { return }
        if (e.type === "updateAvailable") {
            updateCurrent = e.current || ""; updateLatest = e.latest || ""; updateChangelog = e.changelog || []; updateAvailable = true
        } else if (e.type === "workspaces") {
            const first = workspaces.length === 0
            workspaces = e.workspaces || []
            // an identity for compose/search while unfiltered
            if (currentAccount === "" && workspaces.length > 0) currentAccount = workspaces[0].id
            // every account's folders, both for the badges and to resolve each
            // inbox id for the merged fetch
            for (const w of workspaces) send({ type: "folders", account: w.id })
            // restore the last chosen inbox (merged or a single account)
            if (first && currentFolderId === "") _applyBootView()
        } else if (e.type === "folders") {
            // track every account's inbox count for the tab badges
            const inboxF = (e.folders || []).find(f => f.role === "inbox")
            if (inboxF) {
                const m = Object.assign({}, accountUnread)
                m[e.account] = inboxF.unread || 0
                accountUnread = m
            }
            // keep EVERY account's list — the merged fetch needs each inbox id,
            // and they differ per provider
            const fm = Object.assign({}, foldersByAccount)
            fm[e.account] = e.folders || []
            foldersByAccount = fm
            // unified and this account hasn't been fetched yet → now we can
            if (unified && inboxF && _convsByAccount[e.account] === undefined
                    && !_pagingAccounts[e.account])
                _fetchUnifiedFor(e.account)
            if (e.account !== currentAccount) return
            // deterministic order: the daemon may deliver cached + fresh lists
            // with different ordering, which reads as the sidebar reshuffling
            const roleOrder = { inbox: 0, starred: 1, important: 2, sent: 3,
                                drafts: 4, spam: 5, trash: 6, archive: 7 }
            folders = (e.folders || []).map(f =>
                Object.assign({}, f, { section: f.role === "label" ? "labels" : "mailbox" }))
                .sort((a, b) => {
                    if (a.section !== b.section) return a.section === "mailbox" ? -1 : 1
                    const ra = roleOrder[a.role] !== undefined ? roleOrder[a.role] : 50
                    const rb = roleOrder[b.role] !== undefined ? roleOrder[b.role] : 50
                    if (ra !== rb) return ra - rb
                    return (a.name || "").localeCompare(b.name || "")
                })
            if (currentFolderId === "") {
                const inbox = folders.find(f => f.role === "inbox")
                if (inbox) _loadFolder(inbox.id, inbox.name)
            }
        } else if (e.type === "conversations") {
            if (searchView && (e.folder || "") === "") {
                // one frame per account in scope; same keyed merge as Threads.
                // The daemon tags search results with an EMPTY folder (main.go's
                // "search" case) — the only frame that has one, since a folder fetch
                // is never issued without an id. The empty view id it used to imply
                // is what `__search` replaced.
                const sacct = e.account || ""
                if (sacct === "") return
                const sm = Object.assign({}, _convsByAccount)
                sm[sacct] = e.items || []
                _convsByAccount = sm
                loadingConvs = false
                _rebuildMerged()
                return
            }
            if (threadsView && (e.folder || "") === "__threads") {
                // one frame per account in scope; key it and re-merge, so a slow
                // mailbox fills in rather than replacing what already landed
                const tacct = e.account || ""
                if (tacct === "") return
                const tm = Object.assign({}, _convsByAccount)
                tm[tacct] = e.items || []
                _convsByAccount = tm
                loadingConvs = false
                _rebuildMerged()
                return
            }
            if (unified) {
                // merged inbox: accept every account's inbox frame, keyed per
                // account, then re-merge. Other folders' frames are ignored.
                const acct = e.account || ""
                if (acct === "" || (e.folder || "") !== _inboxIdFor(acct)) return
                const paging = !!_pagingAccounts[acct]
                // the cached warm-paint only fills an account we have nothing for
                if (e.cached) {
                    if (_convsByAccount[acct] === undefined) {
                        const cm = Object.assign({}, _convsByAccount)
                        cm[acct] = e.items || []
                        _convsByAccount = cm
                        _rebuildMerged()
                    }
                    return
                }
                loadingConvs = false
                const em = Object.assign({}, acctError); delete em[acct]; acctError = em
                const cm2 = Object.assign({}, _convsByAccount)
                // a page appends to that account's rows; a fresh load replaces them
                cm2[acct] = paging ? (cm2[acct] || []).concat(e.items || []) : (e.items || [])
                _convsByAccount = cm2
                const km = Object.assign({}, cursorByAccount); km[acct] = e.next || ""; cursorByAccount = km
                if (paging) { const pm = Object.assign({}, _pagingAccounts); delete pm[acct]; _pagingAccounts = pm }
                _rebuildMerged()
                return
            }
            if (e.account !== currentAccount) return
            if ((e.folder || "") !== currentFolderId) return
            const items = e.items || []
            if (e.cached) {
                // warm-start paint: fill instantly, but never overwrite a live
                // result that already landed for this folder (races the fetch)
                if (pendingCursor === "" && (convsModel.count === 0
                        || _freshFolder !== currentAccount + "/" + currentFolderId)) {
                    convsModel.clear()
                    for (const c of items) if (findRow(c.id) < 0) convsModel.append(toRow(c))
                    loadingConvs = false
                }
                return
            }
            // live result — authoritative; replaces the cached paint
            loadingConvs = false
            _freshFolder = currentAccount + "/" + currentFolderId
            if (pendingCursor !== "") pendingCursor = ""
            else convsModel.clear()
            // later pages can overlap the stitched unread block — dedup
            for (const c of items) if (findRow(c.id) < 0) convsModel.append(toRow(c))
            nextCursor = e.next || ""
        } else if (e.type === "conversation") {
            if (e.id === openConvId) {
                messages = e.messages || []
                if (pendingRead === e.id) {
                    send({ type: "markread", account: e.account || openConvAccount, id: e.id })
                    setLocalRead(e.id, true, e.account || openConvAccount)
                    pendingRead = ""
                }
            }
        } else if (e.type === "convUpdated") {
            if (!e.conv) return
            if (!unified && e.account !== currentAccount) return
            // Threads and search results are not folder listings: their rows have no
            // folder to be "still in", so the inFolder test below would delete every
            // row a sync tick happens to touch.
            if (threadsView || searchView) return
            const c = e.conv
            const acct = e.account || currentAccount
            // merged: "in folder" means in THAT account's inbox
            const fid = unified ? _inboxIdFor(acct) : currentFolderId
            const inFolder = fid !== "" && (c.folderIds || []).indexOf(fid) >= 0
            const row = toRow(c, acct)
            const i = findRow(c.id, unified ? acct : undefined)
            // keep the raw per-account list in step, or the next rebuild undoes this
            if (unified) {
                const m = Object.assign({}, _convsByAccount)
                const list = (m[acct] || []).filter(x => x.id !== c.id)
                if (inFolder) list.push(c)
                m[acct] = list
                _convsByAccount = m
            }
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
            if (!merged && e.account !== currentAccount) return
            const acct = e.account || currentAccount
            const i = findRow(e.id, merged ? acct : undefined)
            if (i >= 0) convsModel.remove(i)
            if (merged && _convsByAccount[acct]) {
                const m = Object.assign({}, _convsByAccount)
                m[acct] = m[acct].filter(c => c.id !== e.id)
                _convsByAccount = m
            }
            if (openConvId === e.id) closeConv()
        } else if (e.type === "openconv") {
            // deep-link (clicked notification, or an external openconv command):
            // land on the conversation itself. The sender says whether it was
            // unread — a notification always is, so mark-read fires after the
            // fetch; an external link to an already-read thread must NOT fire it,
            // or the folder badge drifts below the real count.
            if (!merged && e.account !== currentAccount) selectAccount(e.account)
            openConv({ tid: e.id, account: e.account, subject: e.subject || "", unread: e.unread === true })
        } else if (e.type === "rules") {
            rules = e.rules || []
        } else if (e.type === "ruleSuggest") {
            ruleCandidates(e.candidates || [], e.note || "")
        } else if (e.type === "filtered") {
            if (!filteredView) return
            const acct = e.account || ""
            const m = Object.assign({}, _convsByAccount); m[acct] = e.items || []; _convsByAccount = m
            loadingConvs = false
            // reuse the merged-inbox rebuild: same shape, one list across accounts
            _rebuildMerged()
        } else if (e.type === "contacts") {
            contactsResult(e.items || [], e.query || "")
        } else if (e.type === "readmarked") {
            if (merged || e.account === currentAccount) setLocalRead(e.id, true, e.account)
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
            const cm = Object.assign({}, _calsByAccount)
            cm[e.account] = e.calendars || []
            _calsByAccount = cm
            // names arriving after the agenda upgrade the filter-chip labels
            if (currentFolderId === "__calendar") _rebuildAgenda()
        } else if (e.type === "rsvped") {
            toast("rsvp saved" + (e.status ? ": " + e.status : ""))
        } else if (e.type === "eventcreated") {
            toast("event created ✓")
            if (currentFolderId === "__calendar") refreshAgenda()
        } else if (e.type === "resync") {
            // daemon detected wake from suspend: refresh what's on screen
            if (unified) selectUnified()
            else if (threadsView) selectThreads()
            else if (searchView) runSearch(searchQuery)
            else if (currentAccount !== "") {
                send({ type: "folders", account: currentAccount })
                if (currentFolderId === "__calendar") refreshAgenda()
                else if (currentFolderId !== "")
                    send({ type: "conversations", account: currentAccount, folder: currentFolderId })
            }
            if (openConvId !== "")
                send({ type: "conversation", account: openConvAccount || currentAccount, id: openConvId })
        } else if (e.type === "summon") {
            summonRequested()
        } else if (e.type === "dismiss") {
            dismissRequested()
        } else if (e.type === "toast") {
            // merged view: a provider failing (bad host, dead auth) toasts per
            // account — mark it and keep whatever else arrived, and stop waiting
            if (merged && e.account && _convsByAccount[e.account] === undefined) {
                const em2 = Object.assign({}, acctError); em2[e.account] = true; acctError = em2
                const cm3 = Object.assign({}, _convsByAccount); cm3[e.account] = []; _convsByAccount = cm3
                loadingConvs = false
                _rebuildMerged()
            }
            if ((e.text || "").indexOf("mlqs send") === 0)
                messages = messages.map(m => m.sending ? Object.assign({}, m, { sending: false, failed: true }) : m)
            toast(e.text || "")
        } else if (e.type === "summary") {
            summaryLoading = false; summaryTimeout.stop()
            summaryText = e.text || ""; summaryScope = e.scope || ""; summaryIds = e.ids || []
            summaryFraming = e.framing || ""
            summaryQA = []
            summaryReady()
        } else if (e.type === "summaryAnswer") {
            summaryAsking = false; summaryTimeout.stop()
            var qa = summaryQA.slice()
            if (qa.length && qa[qa.length - 1].a === "")
                qa[qa.length - 1] = { q: qa[qa.length - 1].q, a: e.text || "" }
            else
                qa = qa.concat([{ q: e.question || "", a: e.text || "" }])
            summaryQA = qa
        } else if (e.type === "summaryError") {
            summaryTimeout.stop()
            if (summaryAsking) {
                summaryAsking = false
                var q2 = summaryQA.slice()
                if (q2.length && q2[q2.length - 1].a === "") q2.pop()
                summaryQA = q2
            }
            summaryLoading = false
            if (e.text) toast(e.text)
        } else if (e.type === "summarizeSetup") {
            summaryLoading = false; summaryTimeout.stop()
            summarizeClis = e.clis || []; summarizeSetupNeeded()
        }
    }

    // The daemon socket is created fresh on every re-dial: a Socket whose
    // connect failed (or whose peer closed) is wedged — toggling `connected`
    // never dials again, and `connected` reads the DESIRED state, so the old
    // running:!sock.connected timer never even fired. Same fix as slqs/dsqrd.
    property var sock: null
    property double lastRecv: 0
    Component {
        id: sockComp
        Socket {
            path: Quickshell.env("XDG_RUNTIME_DIR") + "/mlqs.sock"
            connected: true
            parser: SplitParser { onRead: data => { backend.lastRecv = Date.now(); backend.onEvent(data) } }
            onConnectionStateChanged: {
                if (!connected) return
                // daemon re-sends workspaces on connect; refresh the open view too
                if (backend.unified) backend.selectUnified()
                else if (backend.threadsView) backend.selectThreads()
                else if (backend.searchView) backend.runSearch(backend.searchQuery)
                else if (backend.currentAccount !== "") {
                    backend.send({ type: "folders", account: backend.currentAccount })
                    if (backend.currentFolderId === "__calendar") backend.refreshAgenda()
                    else if (backend.currentFolderId !== "")
                        backend.send({ type: "conversations", account: backend.currentAccount, folder: backend.currentFolderId })
                }
                // an open conversation's fetch died with the old daemon —
                // re-request it or it shows "loading…" forever
                if (backend.openConvId !== "")
                    backend.send({ type: "conversation", account: backend.openConvAccount || backend.currentAccount, id: backend.openConvId })
            }
        }
    }
    function _redial() {
        if (sock) sock.destroy()
        sock = sockComp.createObject(backend)
    }
    Component.onCompleted: _redial()

    // Re-dial whenever the daemon has been silent too long. It pings every
    // 3s, so 8s of silence = dead socket or never connected; a large tick gap
    // means we were suspended/hibernated — re-dial for a fresh bootstrap.
    Timer {
        id: reconnect
        interval: 1000; repeat: true; running: true
        property double lastTick: 0
        property int cooldown: 0
        onTriggered: {
            const now = Date.now()
            const frozen = lastTick > 0 && (now - lastTick) > 20000
            lastTick = now
            if (cooldown > 0 && !frozen) { cooldown--; return }
            if (frozen || (now - backend.lastRecv) > 8000) {
                backend._redial()
                cooldown = 3
            }
        }
    }
}
