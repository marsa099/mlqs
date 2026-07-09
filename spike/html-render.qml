// Spike: how well does Qt's rich-text subset render real-world email HTML?
// j/k = switch sample, s = toggle sanitized/raw, o = dump current HTML to /tmp.
// The JS sanitizer below approximates what the Go daemon-side one would do.
import Quickshell
import QtQuick

ShellRoot {
    FloatingWindow {
        id: win
        title: "mlqs html spike"
        implicitWidth: 760
        implicitHeight: 900
        color: "#ffffff"

        property var samples: ["newsletter.html", "notification.html", "reply.html"]
        property int cur: 0
        property bool sanitized: true
        property string rawHtml: ""

        function load() {
            const x = new XMLHttpRequest()
            x.open("GET", Qt.resolvedUrl("samples/" + samples[cur]))
            x.onreadystatechange = () => {
                if (x.readyState === XMLHttpRequest.DONE) { win.rawHtml = x.responseText }
            }
            x.send()
        }
        Component.onCompleted: load()

        function sanitize(html) {
            let s = html
            s = s.replace(/<!--[\s\S]*?-->/g, "")
            s = s.replace(/<style[\s\S]*?<\/style>/gi, "")
            s = s.replace(/<script[\s\S]*?<\/script>/gi, "")
            s = s.replace(/<head[\s\S]*?<\/head>/gi, "")
            // hidden preheader junk
            s = s.replace(/<div[^>]*display\s*:\s*none[^>]*>[\s\S]*?<\/div>/gi, "")
            // flatten layout tables to blocks; keep data-table cells readable
            s = s.replace(/<\/?(table|tbody|thead|tr)[^>]*>/gi, "\n")
            s = s.replace(/<th[^>]*>/gi, "<div><b>").replace(/<\/th>/gi, "</b></div>")
            s = s.replace(/<td[^>]*>/gi, "<div>").replace(/<\/td>/gi, "</div>")
            // strip presentational attributes (keep href)
            s = s.replace(/\s(style|class|width|height|align|bgcolor|border|cellpadding|cellspacing|dir)="[^"]*"/gi, "")
            // remote images blocked by default (tracking pixels)
            s = s.replace(/<img[^>]*src="https?:[^"]*"[^>]*>/gi, "<i>[image blocked]</i>")
            return s
        }

        Rectangle {
            id: bar
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 34; color: "#1a1a1a"
            Text {
                anchors.centerIn: parent
                text: win.samples[win.cur] + "  ·  " + (win.sanitized ? "SANITIZED" : "RAW")
                      + "    (j/k sample, s toggle, o dump)"
                color: "#ffffff"; font.pixelSize: 13; font.family: "monospace"
            }
        }

        Flickable {
            anchors { top: bar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 16 }
            contentHeight: body.height; clip: true
            Text {
                id: body
                width: parent.width
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                color: "#1a1a1a"
                font.pixelSize: 15
                text: win.sanitized ? win.sanitize(win.rawHtml) : win.rawHtml
                onLinkActivated: link => console.log("link:", link)
            }
        }

        Item {
            anchors.fill: parent; focus: true
            Keys.onPressed: e => {
                if (e.key === Qt.Key_J) { win.cur = (win.cur + 1) % win.samples.length; win.load() }
                else if (e.key === Qt.Key_K) { win.cur = (win.cur + win.samples.length - 1) % win.samples.length; win.load() }
                else if (e.key === Qt.Key_S) { win.sanitized = !win.sanitized }
                else if (e.key === Qt.Key_O) { console.log(win.sanitized ? win.sanitize(win.rawHtml) : win.rawHtml) }
                else if (e.key === Qt.Key_Q) { Qt.quit() }
            }
        }
    }
}
