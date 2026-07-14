import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "."
import QsLib

FloatingWindow {
    id: win
    title: "mail-client"
    implicitWidth: 1480
    implicitHeight: 950
    // reference layout: flat canvas, panes float as cards on it
    color: Theme.bg_alt

    component CapGap: Item { width: 8; height: 1 }

    // warm-summon: the launch script pokes the daemon ("summonui"), which
    // broadcasts to us — the hidden window remaps without a cold start.
    // (qs ipc was unusable here: display filtering + CLI name collisions.)
    Connections {
        target: Backend
        function onSummonRequested() { win.visible = true }
        function onDismissRequested() { win.visible = false }
    }

    readonly property bool insertMode: (Backend.openConvId !== "" && conv.replyHasFocus)
                                       || composer.visible || eventComposer.visible || index.searchFocus
    property string pane: "index"   // "sidebar" | "index"
    readonly property bool calPane: Backend.currentFolderId === "__calendar"
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
        anchors { top: parent.top; left: parent.left; right: parent.right; bottom: statusbar.top }

        MailSidebar {
            id: sidebar
            width: 250; height: parent.height
            active: win.pane === "sidebar"
            onComposeRequested: composer.composeNew()
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
                color: win.insertMode ? Theme.cursor : index.visualMode ? Theme.sky : Theme.green
                Text { renderType: Text.NativeRendering
                    id: modeLabel; anchors.centerIn: parent
                    text: win.insertMode ? "INSERT" : index.visualMode ? "VISUAL" : "NORMAL"
                    color: (parent.color.r * 0.299 + parent.color.g * 0.587 + parent.color.b * 0.114) > 0.5 ? Theme.ink : Theme.brightWhite
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 11; font.weight: 500; font.letterSpacing: 0.5
                }
            }
            Text { renderType: Text.NativeRendering
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
        KeyCap {
            id: helpBadge
            text: "?"
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: cheatSheet.shown = true }
        }
        // Update banner: detect-only (the host applies via flake bump + rebuild),
        // takes over the hint slot when a newer build exists.
        Text { renderType: Text.NativeRendering
            visible: Backend.updateAvailable
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "⟳ update available · " + Backend.updateCurrent + " → " + Backend.updateLatest
            color: Theme.orange
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12
        }
        Row {
            visible: !statusbar.inConv && win.calPane && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "move" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "join" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "o" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "open" }
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
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cancel" }
        }
        Row {
            visible: !statusbar.inConv && !index.visualMode && !win.calPane && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "move" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "g" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "i·t·c·s·d" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "goto" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⌃⇧h" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⌃⇧l" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "account" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "open" }
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
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "v" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "select" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "u" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "undo" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "/" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "search" }
        }
        Row {
            visible: statusbar.inConv && !Backend.updateAvailable
            opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
            anchors.right: helpBadge.left; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "scroll" }
            CapGap {}
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⇧j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "⇧k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "message" }
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
            KeyCap { anchors.verticalCenter: parent.verticalCenter; text: "h" }
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

            // Cheat sheet: driven entirely from here (the shell keeps keyboard
            // focus — handing it to the overlay proved unreliable). esc closes
            // (or clears the filter first), / starts filtering, typing edits it.
            if (cheatSheet.shown) {
                if (e.key === Qt.Key_Escape) {
                    if (cheatSheet.searching || cheatSheet.query) cheatSheet.resetSearch()
                    else cheatSheet.shown = false
                } else if (e.key === Qt.Key_Slash && !cheatSheet.searching) {
                    cheatSheet.searching = true
                } else if (e.key === Qt.Key_Question && !cheatSheet.searching) {
                    cheatSheet.shown = false
                } else if (cheatSheet.searching) {
                    if (e.key === Qt.Key_Backspace) cheatSheet.query = cheatSheet.query.slice(0, -1)
                    else if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 0x20) cheatSheet.query += e.text
                }
                e.accepted = true; return
            }
            if (e.key === Qt.Key_Question) {
                cheatSheet.shown = true; e.accepted = true; return
            }

            // hint mode owns Esc + label letters; any OTHER key drops the
            // hints and handles normally (Shift+J/K message nav, scrolling…)
            if (inConv && conv.hinting) {
                if (e.key === Qt.Key_Escape) { conv.cancelHints(); e.accepted = true; return }
                if (e.text && /^[a-z]$/.test(e.text)) { conv.hintKey(e.text); e.accepted = true; return }
                conv.cancelHints()
            }

            // account switch: Ctrl+Shift+L/H next/prev (before the pane-focus
            // matches below, which would otherwise swallow Ctrl+H/L with shift)
            if (ctrl && (e.modifiers & Qt.ShiftModifier) && (e.key === Qt.Key_L || e.key === Qt.Key_H)) {
                Backend.cycleAccount(e.key === Qt.Key_L ? 1 : -1)
                e.accepted = true; return
            }
            // ⌃⇧r: manual update check (daemon toasts the result)
            if (ctrl && (e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_R) {
                Backend.checkForUpdates(); e.accepted = true; return
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
                case Qt.Key_E: Backend.batchArchive(index.selIds()); index.visualEnd(); break
                case Qt.Key_D: Backend.batchTrash(index.selIds()); index.visualEnd(); break
                case Qt.Key_R: Backend.batchRead(index.selRows()); index.visualEnd(); break
                case Qt.Key_X: Backend.batchStar(index.selRows()); index.visualEnd(); break
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
                case Qt.Key_S: go(shifted ? "spam" : "sent"); e.accepted = true; return
                case Qt.Key_D: go("drafts"); e.accepted = true; return
                case Qt.Key_T:
                    if (shifted) go("trash")
                    else { Backend.selectThreads(); win.pane = "index" }
                    e.accepted = true; return
                case Qt.Key_C: Backend.selectCalendar(); win.pane = "index"; e.accepted = true; return
                }
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
                case Qt.Key_R: Backend.refreshAgenda(); break
                case Qt.Key_Q: win.visible = false; break
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

            // pane focus
            if (ctrl && e.key === Qt.Key_H) { win.pane = "sidebar"; e.accepted = true; return }
            if (ctrl && e.key === Qt.Key_L) { win.pane = "index"; e.accepted = true; return }
            // account switch (cycle; tabs in the sidebar header are clickable too)
            if (ctrl && e.key === Qt.Key_S) { Backend.cycleAccount(1); e.accepted = true; return }
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
                else if (!inConv) index.open()
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
            case Qt.Key_X:
                if (!inConv) Backend.toggleStar(index.current())
                break
            case Qt.Key_Y:
                if (inConv && conv.inviteMsg()) Backend.rsvpMail(conv.inviteMsg().id, "accepted")
                break
            case Qt.Key_M:
                if (inConv && conv.inviteMsg()) Backend.rsvpMail(conv.inviteMsg().id, "tentative")
                break
            case Qt.Key_E:
                if (inConv) Backend.archiveConv(Backend.openConvId)
                else if (index.current()) Backend.archiveConv(index.current().tid)
                break
            case Qt.Key_D:
                if (win.dPending) {
                    win.dPending = false
                    if (inConv) Backend.trashConv(Backend.openConvId)
                    else if (index.current()) Backend.trashConv(index.current().tid)
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
                else win.visible = false   // hide, stay warm — super+m remaps instantly
                break
            case Qt.Key_V:
                if (!inConv && win.pane === "index") index.visualStart()
                break
            case Qt.Key_U:
                if (!inConv) Backend.undoRemove()
                break
            case Qt.Key_F:
                if (inConv && (e.modifiers & Qt.ShiftModifier)) composer.forward(conv.focusedMsg())
                else if (inConv) conv.startHints()
                break
            case Qt.Key_N:
                if (inConv && conv.inviteMsg()) { Backend.rsvpMail(conv.inviteMsg().id, "declined"); break }
                composer.composeNew()
                break

            case Qt.Key_R:
                // in a thread: R picks the focused message as reply target
                if (inConv) conv.replyToFocused()
                else if (e.modifiers & Qt.ShiftModifier) Backend.toggleRead(index.current())
                else Backend.refresh()
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
