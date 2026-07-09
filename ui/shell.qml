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
            const ctrl = e.modifiers & Qt.ControlModifier
            const inConv = Backend.openConvId !== ""

            // pane focus
            if (ctrl && e.key === Qt.Key_H) { win.pane = "sidebar"; e.accepted = true; return }
            if (ctrl && e.key === Qt.Key_L) { win.pane = "index"; e.accepted = true; return }
            // half-page
            if (ctrl && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                const d = e.key === Qt.Key_D ? 1 : -1
                if (inConv) conv.scroll(d)
                else if (win.pane === "index") index.page(d)
                e.accepted = true; return
            }
            if (ctrl) return

            switch (e.key) {
            case Qt.Key_J:
                // in a conversation j/k scroll; Shift+J/K jump between messages
                if (inConv) (e.modifiers & Qt.ShiftModifier) ? conv.move(1) : conv.scrollLine(1)
                else if (win.pane === "sidebar") sidebar.move(1)
                else index.move(1)
                break
            case Qt.Key_K:
                if (inConv) (e.modifiers & Qt.ShiftModifier) ? conv.move(-1) : conv.scrollLine(-1)
                else if (win.pane === "sidebar") sidebar.move(-1)
                else index.move(-1)
                break
            case Qt.Key_Return:
            case Qt.Key_Enter:
                if (win.pane === "sidebar") { sidebar.choose(); win.pane = "index" }
                else if (!inConv) index.open()
                break
            case Qt.Key_Escape:
            case Qt.Key_H:
                if (inConv) Backend.closeConv()
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
                else if (index.current()) Backend.archiveConv(index.current().id)
                break
            case Qt.Key_D:
                if (win.dPending) {
                    win.dPending = false
                    if (inConv) Backend.trashConv(Backend.openConvId)
                    else if (index.current()) Backend.trashConv(index.current().id)
                } else win.arm("d")
                break
            case Qt.Key_O:
                if (inConv) conv.openCurrentHtml()
                break
            case Qt.Key_R:
                if (!inConv) Backend.refresh()
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
