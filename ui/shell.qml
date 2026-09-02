import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "."
import QsLib

FloatingWindow {
    id: win
    title: "mlqs"
    // Bundled OFL serif — the display-title fallback on machines without Sigurd
    // installed (friends). We ship the file so the family always resolves.
    FontLoader { source: Qt.resolvedUrl("InstrumentSerif-Regular.ttf") }
    // explicit: a cold-started UI must show without waiting for a summon
    // (the launcher's summonui broadcast fires before we connect)
    visible: true
    implicitWidth: 1480
    implicitHeight: 950
    // reference layout: flat canvas, panes float as cards on it
    color: Theme.bgDim

    component CapGap: Item { width: 8; height: 1 }

    // q/dismiss hide the window warm (stay alive) for an instant re-show; a
    // compositor-initiated close quits so a killed toplevel cold-starts fresh.
    // Where visible=true re-maps a hidden window (this build) the summon is
    // instant; where it no-ops (#11, some quickshell 0.3.0) the launcher's
    // map-check fails and falls through to a cold start (mlqs-client confirms
    // an actual mapped window), so a failed re-show never leaves a ghost.
    property bool _selfHide: false
    function hideWarm() { _selfHide = true; visible = false; _selfHide = false }
    onVisibleChanged: if (!visible && !_selfHide) Qt.quit()

    Connections {
        target: Backend
        function onSummonRequested() { win.visible = true }
        function onDismissRequested() { win.hideWarm() }
    }

    readonly property bool insertMode: (Backend.openConvId !== "" && conv.replyHasFocus)
                                       || composer.visible || eventComposer.visible || index.searchFocus
    property string pane: "index"   // "sidebar" | "index"
    readonly property bool calPane: Backend.currentFolderId === "__calendar"
    // A capturing mode owns the keyboard: while one is active, global letter
    // keybinds (s = summarize, …) must NOT fire — the mode's own handler claims
    // the letter (a hint/yank label, a cursor motion, a visual selection). This
    // is the single guard against a keybind leaking into a mode.
    readonly property bool capturing: conv.hinting || conv.yanking || conv.cursorMode || index.visualMode
    property bool gPending: false
    property bool dPending: false
    // vim count prefix: digits accumulate, j/k consume ("8j")
    property int pendingCount: 0
    function consumeCount() { const n = pendingCount > 0 ? pendingCount : 1; pendingCount = 0; return n }

    // choosing any folder/view — including by mouse in the sidebar — moves
    // keyboard focus to the content pane
    Connections {
        target: Backend
        function onCurrentFolderIdChanged() { if (Backend.currentFolderId !== "") win.pane = "index" }
    }

    Timer { id: pendingReset; interval: 800; onTriggered: { win.gPending = false; win.dPending = false } }
    function arm(which) {
        if (which === "g") gPending = true; else dPending = true
        pendingReset.restart()
    }

    Row {
        // uniform inset from the window's rounded frame so content padding is
        // harmonious top/left (right + bottom handled by the panes/statusbar)
        anchors { top: parent.top; left: parent.left; right: parent.right; bottom: statusbar.top; topMargin: 12; leftMargin: 12 }

        MailSidebar {
            id: sidebar
            width: 250; height: parent.height
            active: win.pane === "sidebar"
            onComposeRequested: composer.composeNew()
            onAccountMenuRequested: acctDropdown.toggle()
        }

        Item {
            width: parent.width - 250; height: parent.height

            MailIndex {
                id: index
                anchors.fill: parent
                visible: Backend.openConvId === "" && !win.calPane
                active: win.pane === "index" && !win.calPane
                onSearchDone: keys.forceActiveFocus()
            }
            CalendarView {
                id: calview
                anchors.fill: parent
                visible: win.calPane && Backend.openConvId === ""
                active: win.pane === "index"
            }
            ConversationView {
                id: conv
                anchors.fill: parent
                anchors.topMargin: 8; anchors.leftMargin: 4
                anchors.rightMargin: 12; anchors.bottomMargin: 12
                visible: Backend.openConvId !== ""
                onExitInsert: keys.forceActiveFocus()
                onMailtoRequested: addr => composer.composeTo(addr)
                onHideRequested: win.hideWarm()
            }
        }
    }

    // picker-style scrim: dim the app while composing
    Rectangle {
        anchors.fill: parent
        color: Theme.ink; opacity: (composer.visible || eventComposer.visible) ? 0.5 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }

    // account switcher — mounted at the window root so it floats above the
    // sidebar + panes; the trigger pill lives in the sidebar header.
    Dropdown {
        id: acctDropdown
        anchorItem: sidebar.accountAnchor
        gap: 6
        panelWidth: 220
        grabsKeys: true                          // ⌃s opens it focused; j/k navigate
        scrimOpacity: 0.28                       // separate the panel from the sidebar behind
        onClosed: keys.forceActiveFocus()        // hand keyboard back to the router
        // "All accounts" is the first row, not a separate view: picking an account
        // filters the merged inbox (and scopes you to its other folders).
        currentId: Backend.accountFilter
        model: [({
            id: "",
            label: "All accounts",
            badge: Backend.workspaces.reduce((n, w) => n + (Backend.accountUnread[w.id] || 0), 0)
        })].concat(Backend.workspaces.map(w => ({
            id: w.id,
            label: w.name,
            badge: Backend.accountUnread[w.id] || 0
        })))
        onActivated: id => Backend.setFilter(id)
    }

    MailComposer {
        id: composer
        onClosed: keys.forceActiveFocus()
    }

    EventComposer {
        id: eventComposer
        onClosed: keys.forceActiveFocus()
    }

    CheatSheet {
        id: cheatSheet
        z: 100
        onClosed: keys.forceActiveFocus()
    }

    // ctrl+o on a calendar event: full detail without joining (QsLib Modal).
    EventModal {
        id: eventModal
        z: 102
        onClosed: keys.forceActiveFocus()
    }

    // "What's new" modal (QsLib). ⇧U opens it when the update event carried a
    // changelog; the scaffold's ↵ (accepted) applies the update.
    ChangelogModal {
        id: changelog
        z: 101
        entries: Backend.updateChangelog
        fromRev: Backend.updateCurrent
        toRev: Backend.updateLatest
        onAccepted: { close(); Backend.applyUpdate() }
        onClosed: keys.forceActiveFocus()
    }

    // AI summary + adaptive setup guide (QsLib, ported from dsqrd).
    SummaryModal {
        id: summaryModal
        z: 103
        onClosed: keys.forceActiveFocus()
    }
    // Filter rules: z reviews, m seeds from a row, F from a selection.
    RulesModal {
        id: rulesModal
        z: 106
        onClosed: keys.forceActiveFocus()
    }

    SummarizeSetup {
        id: summarizeSetup
        z: 105
        onClosed: keys.forceActiveFocus()
    }
    Connections {
        target: Backend
        function onSummarizePromptNeeded(meta) { summaryModal.openFraming(meta) }
        function onSummaryReady() {
            const meta = Backend.summaryScope === "inbox" ? Backend.currentFolderName : Backend.openConvSubject
            summaryModal.showWith(Backend.summaryText, meta, Backend.summaryScope, Backend.summaryIds, Backend.summaryFraming)
        }
        function onSummarizeSetupNeeded() { summarizeSetup.show() }
    }

    FeedbackPill {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: statusbar.top; anchors.bottomMargin: 8
        Connections {
            target: Backend
            function onToast(text) { toast.show(text) }
        }
    }

    // "Summarizing…" pill (ported from dsqrd) — persistent while a summary is in
    // flight, above the chin; the sidebar button also spins.
    Rectangle {
        id: summarizeBadge
        z: 201
        visible: opacity > 0
        opacity: Backend.summaryLoading ? 1 : 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: statusbar.top; anchors.bottomMargin: 8
        width: sbRow.implicitWidth + 28; height: 32; radius: 8
        color: Theme.mode === "light" ? Theme.ink : Theme.fg
        border.width: 1; border.color: Theme.hairline
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Row {
            id: sbRow; anchors.centerIn: parent; spacing: 8
            Rectangle {
                width: 8; height: 8; radius: 4; color: Theme.cursor
                anchors.verticalCenter: parent.verticalCenter
                SequentialAnimation on opacity {
                    running: Backend.summaryLoading; loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.25; duration: 550 }
                    NumberAnimation { from: 0.25; to: 1; duration: 550 }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Summarizing…"; color: Theme.bg
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13
            }
        }
    }

    // ── statusbar chin (picker-footer style, family spec) ──
    Rectangle {
        id: statusbar
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 36; color: Theme.surface0
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }
        readonly property bool inConv: Backend.openConvId !== ""

        Row {
            id: leftStatus
            anchors.left: parent.left; anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Rectangle {
                width: modeLabel.implicitWidth + 16; height: 22; radius: 7
                anchors.verticalCenter: parent.verticalCenter
                // READ = conv open but no cursor in the text (idle scroll state)
                readonly property string modeName: win.insertMode ? "INSERT"
                    : statusbar.inConv
                        ? (conv.yanking ? "YANK"
                           : conv.anchored ? (conv.linewise ? "V·LINE" : "VISUAL")
                           : conv.cursorMode ? "NORMAL"
                           : Backend.messages.length > 1 ? "READ" : "NORMAL")
                        : (index.visualMode ? "VISUAL" : "NORMAL")
                color: modeName === "INSERT" ? Theme.cursor
                     : modeName === "NORMAL" ? Theme.green
                     : modeName === "READ" ? Theme.surface3
                     : modeName === "YANK" ? Theme.red
                     : Theme.sky
                Text { 
                    id: modeLabel; anchors.centerIn: parent
                    text: parent.modeName
                    color: (parent.color.r * 0.299 + parent.color.g * 0.587 + parent.color.b * 0.114) > 0.5 ? Theme.ink : Theme.brightWhite
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 11; font.weight: 500; font.letterSpacing: 0.5
                }
            }
            Text { 
                anchors.verticalCenter: parent.verticalCenter
                text: "panel: " + (statusbar.inConv ? "conversation" : win.pane)
                      + "   " + Backend.currentFolderName
                      + (win.pendingCount > 0 ? "      " + win.pendingCount : "")
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 12
            }
        }

        // Persistent help affordance — stays pinned in the corner even when
        // the mode-specific hints collapse on a narrow window.
        Row {
            id: helpBadge
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "?" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cheatsheet" }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: cheatSheet.show() }
        }
        // Update banner: detect-only (the host applies via flake bump + rebuild),
        // takes over the hint slot when a newer build exists.
        Text { 
            visible: Backend.updateAvailable
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "⟳ update available · " + Backend.updateCurrent + " → " + Backend.updateLatest + " · U to apply"
            color: Theme.orange
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12
        }
        Row {
            visible: !statusbar.inConv && win.calPane && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "join" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "o" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "open" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⌃o" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "details" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "y" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "m" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "n" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "rsvp" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "s" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "span" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⇧n" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "new" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "r" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "refresh" }
        }
        Row {
            visible: !statusbar.inConv && index.visualMode && !win.calPane && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "extend" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "e" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "archive" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "d" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "trash" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "r" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "read" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "x" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "star" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "s" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "summarize" }
            Icon { anchors.verticalCenter: parent.verticalCenter; name: "sparkle-3"; width: 11; height: 11; color: Theme.fg_muted }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cancel" }
        }
        Row {
            visible: !statusbar.inConv && !index.visualMode && !win.calPane && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "ctrl s" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "accounts" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "x" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "star" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "e" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "archive" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "n" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "compose" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "/" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "search" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "s" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "summarize" }
            Icon { anchors.verticalCenter: parent.verticalCenter; name: "sparkle-3"; width: 11; height: 11; color: Theme.fg_muted }
        }
        Row {
            // only for actual threads (>1 message) — a single message enters
            // cursor mode, so showing this "threads" chin flashed on open (#chin)
            visible: statusbar.inConv && Backend.messages.length > 1 && !conv.cursorMode && !win.insertMode && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⇧j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⇧k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "message" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cursor" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "f" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "links" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "r" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "reply" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⇧f" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "forward" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "a" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "recipients" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "i" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "insert" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "s" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "summarize" }
            Icon { anchors.verticalCenter: parent.verticalCenter; name: "sparkle-3"; width: 11; height: 11; color: Theme.fg_muted }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "h" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "back" }
        }
        Row {   // composing a reply: only the keys that actually work while typing
            visible: statusbar.inConv && win.insertMode && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⌃↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "send" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cancel" }
        }
        Row {
            visible: statusbar.inConv && conv.cursorMode && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "f" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "links" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "v" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "select" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "y" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "yank" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "back" }
        }
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onPressed: e => {
            if (composer.visible || eventComposer.visible) return
            const ctrl = e.modifiers & Qt.ControlModifier
            const inConv = Backend.openConvId !== ""

            // Modals (changelog, cheat sheet) own their own focus + keys via the
            // QsLib Modal scaffold; while one is open it has focus and this router
            // never sees the event.
            if (e.key === Qt.Key_Question) {
                cheatSheet.show(); e.accepted = true; return
            }

            // hint mode owns Esc + label letters; any OTHER key drops the
            // hints and handles normally (Shift+J/K message nav, scrolling…)
            if (inConv && conv.hinting) {
                if (e.key === Qt.Key_Escape) { conv.cancelHints(); e.accepted = true; return }
                if (e.text && /^[a-z]$/.test(e.text)) { conv.hintKey(e.text); e.accepted = true; return }
                conv.cancelHints()
            }

            // y-mode: pick a labeled token to copy; y again = whole message.
            // MUST run before the letter keybinds below (e.g. s = summarize),
            // else a token labeled 's' fires the summary instead of yanking.
            if (inConv && conv.yanking) {
                if (e.key === Qt.Key_Escape || e.key === Qt.Key_Q) { conv.cancelYank(); e.accepted = true; return }
                if (e.key === Qt.Key_Y) { conv.yankWholeMessage(); e.accepted = true; return }
                if (e.text && /^[a-z]$/.test(e.text)) { conv.yankKey(e.text); e.accepted = true; return }
                conv.cancelYank()
            }

            // account switch: Ctrl+Shift+L/H next/prev (before the pane-focus
            // matches below, which would otherwise swallow Ctrl+H/L with shift)
            if (ctrl && (e.modifiers & Qt.ShiftModifier) && (e.key === Qt.Key_L || e.key === Qt.Key_H)) {
                Backend.cycleAccount(e.key === Qt.Key_L ? 1 : -1)
                e.accepted = true; return
            }
            // ⌃r: refresh the current view (⇧r now marks the view read)
            if (ctrl && !(e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_R) {
                Backend.refresh(); e.accepted = true; return
            }
            // ⌃⇧r: manual update check (daemon toasts the result)
            if (ctrl && (e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_R) {
                Backend.checkForUpdates(); e.accepted = true; return
            }
            // ⌃s: open + focus the account switcher (j/k move, ↵ select, esc close)
            if (ctrl && !(e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_S) {
                acctDropdown.show(); e.accepted = true; return
            }
            // AI summary (sparkle): S = the focused message; s = this thread (in a
            // conversation) / the focused inbox (in the index). Gated off the g-goto
            // prefix (gs/gS) and the calendar pane.
            if (!ctrl && !win.gPending && !win.capturing && (e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_S && inConv) {
                const fm = conv.focusedMsg()
                if (fm && fm.id) Backend.summarize("message", fm.id, Backend.openConvId)
                e.accepted = true; return
            }
            if (!ctrl && !win.gPending && !win.capturing && !(e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_S) {
                if (inConv) { Backend.summarize("thread", Backend.openConvId); e.accepted = true; return }
                if (!win.calPane && win.pane === "index") { Backend.summarize("inbox", ""); e.accepted = true; return }
            }
            // ⌃o on a calendar event: open its full detail (no joining).
            if (ctrl && !(e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_O
                    && win.calPane && !inConv && win.pane === "index") {
                const ev = calview.current()
                if (ev) eventModal.showEvent(ev)
                e.accepted = true; return
            }
            // ⇧U: show "what's new" if the update carried a changelog, else apply
            // straight away. Gated on updateAvailable so it never shadows u=undo.
            if (!ctrl && (e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_U && Backend.updateAvailable) {
                if (Backend.updateChangelog.length > 0) changelog.show(); else Backend.applyUpdate()
                e.accepted = true; return
            }
            // visual mode owns the keyboard in the index
            if (!inConv && index.visualMode) {
                // ⌃d/⌃u stay navigation here too — half-page moves the cursor,
                // which extends the visual range (vim parity). Must run before
                // the letter switch, or ⌃d falls into the d=trash case.
                if (ctrl && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                    index.page(e.key === Qt.Key_D ? 1 : -1)
                    e.accepted = true; return
                }
                switch (e.key) {
                case Qt.Key_J: index.move(win.consumeCount()); break
                case Qt.Key_K: index.move(-win.consumeCount()); break
                case Qt.Key_G:
                    if (e.modifiers & Qt.ShiftModifier) index.toEnd()
                    else if (win.gPending) { win.gPending = false; index.toTop() }
                    else win.arm("g")
                    break
                case Qt.Key_E: Backend.batchArchive(index.selRows()); index.visualEnd(); break
                case Qt.Key_D: Backend.batchTrash(index.selRows()); index.visualEnd(); break
                case Qt.Key_R: Backend.batchRead(index.selRows()); index.visualEnd(); break
                case Qt.Key_X: Backend.batchStar(index.selRows()); index.visualEnd(); break
                case Qt.Key_S: { const sel = index.selIds(); index.visualEnd(); Backend.summarizeSelection(sel); break }
                // ⇧F: what do these have in common? → candidate filters
                case Qt.Key_F: { const rows = index.selRows(); index.visualEnd(); rulesModal.showFor(rows); break }
                case Qt.Key_Escape:
                case Qt.Key_V:
                case Qt.Key_Q: index.visualEnd(); break
                default:
                    if (e.key >= Qt.Key_0 && e.key <= Qt.Key_9) {
                        const digit = e.key - Qt.Key_0
                        if (digit !== 0 || win.pendingCount > 0) win.pendingCount = win.pendingCount * 10 + digit
                    }
                    e.accepted = true; return
                }
                e.accepted = true; return
            }

            // Calendar-invite RSVP: ⇧Y accept · m maybe · n decline. MUST run before
            // the cursor-mode block, which owns y/⇧Y for yanking and swallows every
            // other key — and an invite is always a single-message conversation, which
            // auto-enters cursor mode, so the copies in the main switch below were
            // unreachable. Accept is ⇧Y, not y, because y is the yank prefix.
            // NOT gated on win.capturing: that is true whenever cursorMode is
            // (see its definition), which is precisely the state this must survive.
            if (inConv && !ctrl && !win.gPending) {
                const inv = conv.inviteMsg()
                if (inv) {
                    const shifted = e.modifiers & Qt.ShiftModifier
                    if (shifted && e.key === Qt.Key_Y) {
                        Backend.rsvpMail(inv.id, "accepted"); e.accepted = true; return
                    }
                    if (!shifted && e.key === Qt.Key_M) {
                        Backend.rsvpMail(inv.id, "tentative"); e.accepted = true; return
                    }
                    if (!shifted && e.key === Qt.Key_N) {
                        Backend.rsvpMail(inv.id, "declined"); e.accepted = true; return
                    }
                }
            }

            // in-message cursor mode owns the keyboard in a conversation:
            // motions move the cursor, v anchors a selection, y yanks it.
            // Everything not handled is swallowed (e must not archive mid-select)
            if (inConv && conv.cursorMode) {
                // vim scrolling: ⌃d/⌃u move the cursor half a viewport,
                // ⌃e/⌃y scroll the view a line. Before the letter switch or
                // ⌃d would fall into d, ⌃e into e (word-end).
                if (ctrl && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                    conv.vHalfPage(e.key === Qt.Key_D ? 1 : -1)
                    e.accepted = true; return
                }
                if (ctrl && (e.key === Qt.Key_E || e.key === Qt.Key_Y)) {
                    conv.vScroll(e.key === Qt.Key_E ? 1 : -1)
                    e.accepted = true; return
                }
                if (ctrl) {
                    // unhandled ctrl-chords fall through to the global handlers
                } else if (!((e.modifiers & Qt.ShiftModifier) && (e.key === Qt.Key_I || e.key === Qt.Key_T || e.key === Qt.Key_C))) {
                // ⇧I/⇧T/⇧C are global jumps (inbox/threads/calendar) — don't let
                // the reply/motion switch eat them; fall through to the goto below
                switch (e.key) {
                case Qt.Key_H:
                    // bar-only state: h backs out (thread → read, single → inbox)
                    if (!conv.showCursor) {
                        conv.cursorExit()
                        if (Backend.messages.length <= 1) Backend.closeConv()
                    } else conv.vChar(-win.consumeCount())
                    break
                case Qt.Key_L: conv.vChar(win.consumeCount()); break
                case Qt.Key_J:
                    if (e.modifiers & Qt.ShiftModifier) {
                        conv.cursorExit(); conv.move(1)
                        Qt.callLater(function() { conv.cursorEnter(true) })
                    } else conv.vLine(win.consumeCount())
                    break
                case Qt.Key_K:
                    if (e.modifiers & Qt.ShiftModifier) {
                        conv.cursorExit(); conv.move(-1)
                        Qt.callLater(function() { conv.cursorEnter(true) })
                    } else conv.vLine(-win.consumeCount())
                    break
                case Qt.Key_W: conv.vWord(e.modifiers & Qt.ShiftModifier ? "W" : "w", win.consumeCount()); break
                case Qt.Key_B: conv.vWord(e.modifiers & Qt.ShiftModifier ? "B" : "b", win.consumeCount()); break
                case Qt.Key_E: conv.vWord(e.modifiers & Qt.ShiftModifier ? "E" : "e", win.consumeCount()); break
                case Qt.Key_Dollar: conv.vLineEnd(); break
                case Qt.Key_AsciiCircum: conv.vLineFirst(); break
                case Qt.Key_G:
                    if (e.modifiers & Qt.ShiftModifier) conv.vDocEnd()
                    else conv.vDocStart()
                    break
                case Qt.Key_O: conv.vSwap(); break
                case Qt.Key_Y:
                    if (e.modifiers & Qt.ShiftModifier) conv.yankWholeMessage()
                    else conv.vYank()
                    break
                case Qt.Key_V:
                    if (e.modifiers & Qt.ShiftModifier) conv.lineToggle()
                    else conv.visualToggle()
                    break
                case Qt.Key_F: conv.startHints(); break
                case Qt.Key_I: conv.cursorExit(); conv.focusReply(); break
                case Qt.Key_Escape:
                    if (conv.anchored) conv.dropAnchor()
                    else if (conv.showCursor) conv.showCursor = false
                    else if (Backend.messages.length > 1) conv.cursorExit()
                    break
                case Qt.Key_Q: conv.cursorExit(); Backend.closeConv(); break
                default:
                    if (e.key >= Qt.Key_0 && e.key <= Qt.Key_9) {
                        const digit = e.key - Qt.Key_0
                        if (digit === 0 && win.pendingCount === 0) conv.vLineStart()
                        else win.pendingCount = win.pendingCount * 10 + digit
                    } else if (e.text === "^") conv.vLineFirst()
                    e.accepted = true; return
                }
                e.accepted = true; return
                }
            }

            // g-prefix goto, case-sensitive: gg top · gi inbox · gI important
            // · gt threads · gT trash · gc calendar · gs sent · gS spam · gd drafts
            // bare modifier presses must not eat the g-prefix (g→⇧→I is
            // three key events; Shift alone would clear the pending flag)
            if (win.gPending && e.key !== Qt.Key_Shift && e.key !== Qt.Key_Control
                    && e.key !== Qt.Key_Alt && e.key !== Qt.Key_Meta) {
                win.gPending = false
                const shifted = e.modifiers & Qt.ShiftModifier
                const go = r => { Backend.jumpRole(r); win.pane = "index" }
                switch (e.key) {
                case Qt.Key_G:
                    if (!shifted) {
                        if (inConv) conv.toTop()
                        else if (win.calPane) calview.toTop()
                        else index.toTop()
                        e.accepted = true; return
                    }
                    break
                case Qt.Key_I: go(shifted ? "starred" : "inbox"); e.accepted = true; return
                case Qt.Key_F:
                    // gf: the Filtered list — everything the rules hid
                    Backend.selectFiltered(); win.pane = "index"; e.accepted = true; return
                case Qt.Key_U:
                    // gu: back to the merged inbox (All accounts)
                    Backend.selectUnified(); win.pane = "index"; e.accepted = true; return
                case Qt.Key_S: go(shifted ? "spam" : "sent"); e.accepted = true; return
                case Qt.Key_D: go("drafts"); e.accepted = true; return
                case Qt.Key_T:
                    if (shifted) go("trash")
                    else { Backend.selectThreads(); win.pane = "index" }
                    e.accepted = true; return
                case Qt.Key_C: Backend.selectCalendar(); win.pane = "index"; e.accepted = true; return
                }
            }

            // shifted goto — ⇧I inbox · ⇧T threads · ⇧C calendar. Top-level
            // jumps from anywhere outside a text field; g-prefix still works.
            if ((e.modifiers & Qt.ShiftModifier) && !ctrl) {
                if (e.key === Qt.Key_I) { Backend.jumpRole("inbox"); win.pane = "index"; e.accepted = true; return }
                if (e.key === Qt.Key_T) { Backend.selectThreads(); win.pane = "index"; e.accepted = true; return }
                if (e.key === Qt.Key_C) { Backend.selectCalendar(); win.pane = "index"; e.accepted = true; return }
            }

            // calendar pane owns the right panel's keys
            if (win.calPane && !inConv && win.pane === "index" && !ctrl) {
                switch (e.key) {
                case Qt.Key_J: calview.move(win.consumeCount()); break
                case Qt.Key_K: calview.move(-win.consumeCount()); break
                case Qt.Key_G:
                    if (e.modifiers & Qt.ShiftModifier) calview.toEnd()
                    else if (win.gPending) { win.gPending = false; calview.toTop() }
                    else win.arm("g")
                    break
                case Qt.Key_Return:
                case Qt.Key_Enter: calview.open(); break
                case Qt.Key_O: calview.openBrowser(); break
                case Qt.Key_Y: calview.rsvp("accepted"); break
                case Qt.Key_M: calview.rsvp("tentative"); break
                case Qt.Key_N:
                    if (e.modifiers & Qt.ShiftModifier) eventComposer.composeNew()
                    else calview.rsvp("declined")
                    break
                case Qt.Key_S: calview.cycleSpan(); break
                case Qt.Key_Tab: Backend.cycleCalFilter(1); break
                case Qt.Key_Backtab: Backend.cycleCalFilter(-1); break
                case Qt.Key_X: Backend.toggleHideCal(); break
                case Qt.Key_R: Backend.refreshAgenda(); break
                case Qt.Key_Q: win.hideWarm(); break
                case Qt.Key_H: win.pane = "sidebar"; break
                default:
                    if (e.key >= Qt.Key_0 && e.key <= Qt.Key_9) {
                        const digit = e.key - Qt.Key_0
                        if (digit !== 0 || win.pendingCount > 0) win.pendingCount = win.pendingCount * 10 + digit
                    }
                    e.accepted = true; return
                }
                e.accepted = true; return
            }

            // pane focus — ⌃h always reaches the sidebar, even from a message
            if (ctrl && e.key === Qt.Key_H) {
                if (inConv) { conv.cursorExit(); Backend.closeConv() }
                win.pane = "sidebar"; e.accepted = true; return
            }
            if (ctrl && e.key === Qt.Key_L) { win.pane = "index"; e.accepted = true; return }
            // account switch (cycle; tabs in the sidebar header are clickable too)
            // half-page
            if (ctrl && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                const d = e.key === Qt.Key_D ? 1 : -1
                if (inConv) conv.scroll(d)
                else if (win.pane === "index") (win.calPane ? calview : index).page(d)
                e.accepted = true; return
            }
            if (ctrl) return


            // count prefix digits (0 only continues an existing count)
            if (e.key >= Qt.Key_0 && e.key <= Qt.Key_9) {
                const digit = e.key - Qt.Key_0
                if (digit !== 0 || win.pendingCount > 0) {
                    win.pendingCount = win.pendingCount * 10 + digit
                    e.accepted = true; return
                }
            }
            if (e.key !== Qt.Key_J && e.key !== Qt.Key_K) win.pendingCount = 0

            switch (e.key) {
            case Qt.Key_J: {
                const n = win.consumeCount()
                // in a conversation j/k scroll; Shift+J/K jump between messages
                if (inConv) (e.modifiers & Qt.ShiftModifier) ? conv.move(n) : conv.scrollLine(n)
                else if (win.pane === "sidebar") sidebar.move(n)
                else index.move(n)
                break
            }
            case Qt.Key_K: {
                const n = win.consumeCount()
                if (inConv) (e.modifiers & Qt.ShiftModifier) ? conv.move(-n) : conv.scrollLine(-n)
                else if (win.pane === "sidebar") sidebar.move(-n)
                else index.move(-n)
                break
            }
            case Qt.Key_Return:
            case Qt.Key_Enter:
                if (win.pane === "sidebar") { sidebar.choose(); win.pane = "index" }
                else if (inConv) conv.cursorEnter(false)
                else index.open()
                break
            case Qt.Key_H:
                // spatial: conversation → index → sidebar
                if (inConv) Backend.closeConv()
                else if (win.pane === "index") win.pane = "sidebar"
                break
            case Qt.Key_Escape:
                // cancel-only (hints/search/composer handle their own Esc);
                // navigation is h's job — Esc must never eject you from a view
                break
            case Qt.Key_L:
                if (!inConv && win.pane === "index") index.open()
                else if (win.pane === "sidebar") win.pane = "index"
                break
            case Qt.Key_G:
                if (e.modifiers & Qt.ShiftModifier) {
                    if (inConv) conv.toEnd(); else index.toEnd()
                } else win.arm("g")
                break
            case Qt.Key_Z:
                if (!inConv) rulesModal.showAll()
                break
            case Qt.Key_M:
                // m: start a filter from this message's sender
                if (!inConv && index.current()) rulesModal.showFor([index.current()])
                break
            case Qt.Key_X:
                if (!inConv) Backend.toggleStar(index.current())
                break
            case Qt.Key_Y:
                // invite accept is ⇧Y, handled above (before cursor mode)
                if (inConv && (e.modifiers & Qt.ShiftModifier)) conv.yankWholeMessage()
                else if (inConv) conv.startYank()
                break
            case Qt.Key_E:
                if (inConv) Backend.archiveConv({ tid: Backend.openConvId, account: Backend.openConvAccount })
                else if (index.current()) Backend.archiveConv(index.current())
                break
            case Qt.Key_D:
                if (win.dPending) {
                    win.dPending = false
                    if (inConv) Backend.trashConv({ tid: Backend.openConvId, account: Backend.openConvAccount })
                    else if (index.current()) Backend.trashConv(index.current())
                } else win.arm("d")
                break
            case Qt.Key_I:
                if (inConv) conv.focusReply()
                break
            case Qt.Key_A:
                if (inConv) Backend.openConvId !== "" && (conv.replyAll = !conv.replyAll)
                break
            case Qt.Key_O:
                if (inConv) conv.openCurrentHtml()
                break
            case Qt.Key_Q:
                if (inConv) Backend.closeConv()
                else win.hideWarm()   // hide warm; launcher re-shows or cold-starts (#11)
                break
            case Qt.Key_V:
                if (inConv) { if (conv.cursorEnter(false)) conv.visualToggle() }
                else if (win.pane === "index") index.visualStart()
                break
            case Qt.Key_U:
                if (!inConv) Backend.undoRemove()
                break
            case Qt.Key_F:
                if (inConv && (e.modifiers & Qt.ShiftModifier)) composer.forward(conv.focusedMsg())
                else if (inConv) conv.startHints()
                break
            case Qt.Key_N:
                // invite decline is handled above (before cursor mode)
                composer.composeNew()
                break

            case Qt.Key_R:
                // in a thread: R picks the focused message as reply target
                if (inConv) conv.replyToFocused()
                // ⇧R marks everything unread in the current view read (refresh moved
                // to ⌃r) — scoped to what's on screen, so unfiltered it spans accounts
                else if (e.modifiers & Qt.ShiftModifier) Backend.markViewRead()
                else Backend.toggleRead(index.current())
                break
            case Qt.Key_Slash:
                if (!inConv) index.focusSearch()
                break
            default:
                return
            }
            e.accepted = true
        }
    }
}
