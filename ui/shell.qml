import QtQuick
import QtQuick.Controls
import Quickshell
import "."

FloatingWindow {
    id: win
    title: "mail-client"
    implicitWidth: 1480
    implicitHeight: 950
    color: Theme.bg

    property string pane: "index"   // "sidebar" | "index"
    property bool gPending: false
    property bool dPending: false
    // vim count prefix: digits accumulate, j/k consume ("8j")
    property int pendingCount: 0
    function consumeCount() { const n = pendingCount > 0 ? pendingCount : 1; pendingCount = 0; return n }

    Timer { id: pendingReset; interval: 500; onTriggered: { win.gPending = false; win.dPending = false } }
    function arm(which) {
        if (which === "g") gPending = true; else dPending = true
        pendingReset.restart()
    }

    Row {
        anchors.fill: parent

        MailSidebar {
            id: sidebar
            width: 250; height: parent.height
            active: win.pane === "sidebar"
        }
        Rectangle { width: 1; height: parent.height; color: Theme.hairline }

        Item {
            width: parent.width - 251; height: parent.height

            MailIndex {
                id: index
                anchors.fill: parent
                visible: Backend.openConvId === ""
                active: win.pane === "index"
            }
            ConversationView {
                id: conv
                anchors.fill: parent
                visible: Backend.openConvId !== ""
            }
        }
    }

    // search input ('/')
    Rectangle {
        id: searchBox
        visible: false
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top; anchors.topMargin: 60
        width: 520; height: 44
        radius: Theme.radius; color: Theme.overlay
        border.color: Theme.hairline; border.width: 1
        function open() { visible = true; searchInput.text = ""; searchInput.forceActiveFocus() }
        function close() { visible = false; keys.forceActiveFocus() }
        TextField {
            id: searchInput
            anchors.fill: parent; anchors.margins: 6
            color: Theme.fg
            placeholderText: "search mail…  (Gmail syntax: from:, is:unread, has:attachment)"
            placeholderTextColor: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: 13
            background: null
            Keys.onPressed: e => {
                if (e.key === Qt.Key_Escape) { searchBox.close(); e.accepted = true }
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    if (text.trim() !== "") Backend.runSearch(text.trim())
                    searchBox.close(); e.accepted = true
                }
            }
        }
    }

    MailComposer {
        id: composer
        onClosed: keys.forceActiveFocus()
    }

    // toast
    Rectangle {
        id: toast
        visible: opacity > 0
        opacity: 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 24
        width: toastText.implicitWidth + 28; height: 34
        radius: Theme.radius; color: Theme.overlay
        border.color: Theme.hairline; border.width: 1
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Text {
            id: toastText
            renderType: Text.NativeRendering
            anchors.centerIn: parent
            color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 12
        }
        Timer { id: toastHide; interval: 3000; onTriggered: toast.opacity = 0 }
        Connections {
            target: Backend
            function onToast(text) { toastText.text = text; toast.opacity = 1; toastHide.restart() }
        }
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onPressed: e => {
            if (composer.visible) return
            const ctrl = e.modifiers & Qt.ControlModifier
            const inConv = Backend.openConvId !== ""

            // hint mode captures the keyboard until a label matches or Esc
            if (inConv && conv.hinting) {
                if (e.key === Qt.Key_Escape) conv.cancelHints()
                else if (e.text && /^[a-z]$/.test(e.text)) conv.hintKey(e.text)
                e.accepted = true; return
            }

            // account switch: Ctrl+Shift+L/H next/prev (before the pane-focus
            // matches below, which would otherwise swallow Ctrl+H/L with shift)
            if (ctrl && (e.modifiers & Qt.ShiftModifier) && (e.key === Qt.Key_L || e.key === Qt.Key_H)) {
                Backend.cycleAccount(e.key === Qt.Key_L ? 1 : -1)
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
                else if (win.pane === "index") index.page(d)
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
            case Qt.Key_Escape:
            case Qt.Key_H:
                // spatial: conversation → index → sidebar
                if (inConv) Backend.closeConv()
                else if (win.pane === "index") win.pane = "sidebar"
                break
            case Qt.Key_L:
                if (!inConv && win.pane === "index") index.open()
                else if (win.pane === "sidebar") win.pane = "index"
                break
            case Qt.Key_G:
                if (e.modifiers & Qt.ShiftModifier) {
                    if (inConv) conv.toEnd(); else index.toEnd()
                } else if (win.gPending) {
                    win.gPending = false
                    if (inConv) conv.toTop(); else index.toTop()
                } else win.arm("g")
                break
            case Qt.Key_X:
                if (!inConv) Backend.toggleStar(index.current())
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
            case Qt.Key_O:
                if (inConv) conv.openCurrentHtml()
                break
            case Qt.Key_F:
                if (inConv) conv.startHints()
                break
            case Qt.Key_C:
                composer.composeNew()
                break
            case Qt.Key_R:
                if (inConv) composer.reply(!!(e.modifiers & Qt.ShiftModifier))
                else if (e.modifiers & Qt.ShiftModifier) Backend.toggleRead(index.current())
                else Backend.refresh()
                break
            case Qt.Key_Slash:
                searchBox.open()
                break
            default:
                return
            }
            e.accepted = true
        }
    }
}
