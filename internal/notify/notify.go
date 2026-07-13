// Package notify sends D-Bus notifications carrying a default action, so
// the bar's jump picker (Super+i) can deep-link into the conversation —
// plain notify-send can only focus the app. Same design as slqs's notifier.
package notify

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	enotify "github.com/esiqveland/notify"
	"github.com/godbus/dbus/v5"
)

type keyEntry struct {
	Key string `json:"k"`
	At  int64  `json:"t"`
}

type Notifier struct {
	mu       sync.Mutex
	conn     *dbus.Conn
	notifier enotify.Notifier
	keys     map[uint32]keyEntry
	onAct    func(key, action string)
}

// New connects a private session bus (so AppName stays "mlqs" downstream).
// On any failure the notifier degrades to notify-send without actions.
// keys persist to disk so a daemon restart doesn't orphan the deep-links of
// notifications already sitting in the notification center
func keysPath() string {
	return filepath.Join(os.Getenv("HOME"), ".cache", "mlqs", "notif-keys.json")
}

func (n *Notifier) load() {
	b, err := os.ReadFile(keysPath())
	if err != nil {
		return
	}
	var m map[string]keyEntry
	if json.Unmarshal(b, &m) == nil {
		for k, v := range m {
			if id, err := strconv.ParseUint(k, 10, 32); err == nil && v.Key != "" {
				n.keys[uint32(id)] = v
			}
		}
		return
	}
	// pre-timestamp format: bare key strings
	var old map[string]string
	if json.Unmarshal(b, &old) != nil {
		return
	}
	now := time.Now().Unix()
	for k, v := range old {
		if id, err := strconv.ParseUint(k, 10, 32); err == nil {
			n.keys[uint32(id)] = keyEntry{Key: v, At: now}
		}
	}
}

// save is called with n.mu held. Keys outlive invoke/close so the bar's
// notification history can re-dispatch them; age is the only eviction.
func (n *Notifier) save() {
	cutoff := time.Now().AddDate(0, 0, -14).Unix()
	m := map[string]keyEntry{}
	for id, v := range n.keys {
		if v.At < cutoff {
			delete(n.keys, id)
			continue
		}
		m[strconv.FormatUint(uint64(id), 10)] = v
	}
	b, _ := json.Marshal(m)
	os.MkdirAll(filepath.Dir(keysPath()), 0o700)
	os.WriteFile(keysPath(), b, 0o600)
}

func New(onActivate func(key, action string)) *Notifier {
	n := &Notifier{keys: map[uint32]keyEntry{}, onAct: onActivate}
	n.load()
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
	if sig.ActionKey != "default" && sig.ActionKey != "read" {
		return
	}
	n.mu.Lock()
	key := n.keys[sig.ID].Key
	n.mu.Unlock()
	if key != "" && n.onAct != nil {
		n.onAct(key, sig.ActionKey)
	}
}

func (n *Notifier) handleClosed(sig *enotify.NotificationClosedSignal) {}

// InvokeByID re-dispatches a notification's action by server id — the bar's
// history fallback for entries whose live D-Bus object is gone (invoked or
// closed notifications, or a quickshell restart).
func (n *Notifier) InvokeByID(id uint32, action string) bool {
	if action != "default" && action != "read" {
		return false
	}
	n.mu.Lock()
	key := n.keys[id].Key
	n.mu.Unlock()
	if key == "" || n.onAct == nil {
		return false
	}
	n.onAct(key, action)
	return true
}

func (n *Notifier) Connected() bool { return n.conn != nil }

func (n *Notifier) Notify(key, title, body string) {
	n.NotifyWith(key, title, body, "mail-unread", []enotify.Action{
		enotify.NewDefaultAction(""),
		{Key: "read", Label: "Mark read"},
	})
}

// NotifyEvent is the calendar-reminder shape: Join action, calendar icon.
func (n *Notifier) NotifyEvent(key, title, body string) {
	n.NotifyWith(key, title, body, "x-office-calendar", []enotify.Action{
		enotify.NewDefaultAction(""),
		{Key: "join", Label: "Join"},
	})
}

// NotifyWith sends a notification with caller-chosen icon and actions —
// calendar reminders carry a Join action instead of Mark read.
func (n *Notifier) NotifyWith(key, title, body, icon string, actions []enotify.Action) {
	if n.conn == nil {
		exec.Command("notify-send", "-a", "mlqs", "-i", icon, title, body).Start()
		return
	}
	note := enotify.Notification{
		AppName:       "mlqs",
		AppIcon:       icon,
		Summary:       title,
		Body:          body,
		Actions:       actions,
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
	n.keys[id] = keyEntry{Key: key, At: time.Now().Unix()}
	n.save()
	n.mu.Unlock()
}
