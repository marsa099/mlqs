// Package notify sends D-Bus notifications carrying a default action, so
// the bar's jump picker (Super+i) can deep-link into the conversation —
// plain notify-send can only focus the app. Same design as slqs's notifier.
package notify

import (
	"os/exec"
	"sync"

	enotify "github.com/esiqveland/notify"
	"github.com/godbus/dbus/v5"
)

type Notifier struct {
	mu       sync.Mutex
	conn     *dbus.Conn
	notifier enotify.Notifier
	keys     map[uint32]string
	onAct    func(key string)
}

// New connects a private session bus (so AppName stays "mlqs" downstream).
// On any failure the notifier degrades to notify-send without actions.
func New(onActivate func(key string)) *Notifier {
	n := &Notifier{keys: map[uint32]string{}, onAct: onActivate}
	conn, err := dbus.SessionBusPrivate()
	if err != nil {
		return n
	}
	if err := conn.Auth(nil); err != nil {
		conn.Close()
		return n
	}
	if err := conn.Hello(); err != nil {
		conn.Close()
		return n
	}
	n.conn = conn
	if en, err := enotify.New(conn,
		enotify.WithOnAction(func(sig *enotify.ActionInvokedSignal) { n.handleAction(sig) }),
		enotify.WithOnClosed(func(sig *enotify.NotificationClosedSignal) { n.handleClosed(sig) }),
	); err == nil {
		n.notifier = en
	}
	return n
}

func (n *Notifier) handleAction(sig *enotify.ActionInvokedSignal) {
	if sig.ActionKey != "default" {
		return
	}
	n.mu.Lock()
	key := n.keys[sig.ID]
	delete(n.keys, sig.ID)
	n.mu.Unlock()
	if key != "" && n.onAct != nil {
		n.onAct(key)
	}
}

func (n *Notifier) handleClosed(sig *enotify.NotificationClosedSignal) {
	n.mu.Lock()
	delete(n.keys, sig.ID)
	n.mu.Unlock()
}

func (n *Notifier) Connected() bool { return n.conn != nil }

func (n *Notifier) Notify(key, title, body string) {
	if n.conn == nil {
		exec.Command("notify-send", "-a", "mlqs", "-i", "mail-unread", title, body).Start()
		return
	}
	note := enotify.Notification{
		AppName:       "mlqs",
		AppIcon:       "mail-unread",
		Summary:       title,
		Body:          body,
		Actions:       []enotify.Action{enotify.NewDefaultAction("")},
		ExpireTimeout: enotify.ExpireTimeoutSetByNotificationServer,
	}
	var id uint32
	var err error
	if n.notifier != nil {
		id, err = n.notifier.SendNotification(note)
	} else {
		id, err = enotify.SendNotification(n.conn, note)
	}
	if err != nil {
		return
	}
	n.mu.Lock()
	n.keys[id] = key
	n.mu.Unlock()
}
